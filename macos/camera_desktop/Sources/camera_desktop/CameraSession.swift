import AVFoundation
import FlutterMacOS
import QuartzCore

/// Manages a persistent shared buffer for zero-copy FFI image stream delivery.
/// Native writes frame data here; Dart reads it directly via FFI pointer.
/// Uses a double-buffer strategy so writeFrame() never holds the lock during memcpy.
class ImageStreamFFI {
    // Buffer layout matches C struct ImageStreamBuffer:
    //   int64_t sequence (8 bytes, offset 0)
    //   int32_t width (4 bytes, offset 8)
    //   int32_t height (4 bytes, offset 12)
    //   int32_t bytes_per_row (4 bytes, offset 16)
    //   int32_t format (4 bytes, offset 20) -- 0=BGRA, 1=RGBA
    //   int32_t ready (4 bytes, offset 24) -- 1=ready for Dart, 0=being written
    //   int32_t _pad (4 bytes, offset 28)
    //   uint8_t pixels[] (offset 32)
    static let headerSize = 32

    private var buffers: (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) = (nil, nil)
    private var bufferSizes: (Int, Int) = (0, 0)
    private var frontIndex: Int = 0  // 0 or 1, which buffer Dart reads from
    private var callback: (@convention(c) (Int32) -> Void)?
    private var sequence: Int64 = 0
    private var _disposed = false
    private let lock = UnfairLock()

    func getBufferPointer() -> UnsafeMutableRawPointer? {
        lock.lock()
        guard !_disposed else { lock.unlock(); return nil }
        let idx = frontIndex
        lock.unlock()
        return idx == 0 ? buffers.0 : buffers.1
    }

    var hasCallback: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func registerCallback(_ cb: @convention(c) (Int32) -> Void) {
        lock.lock()
        callback = cb
        lock.unlock()
    }

    func unregisterCallback() {
        lock.lock()
        callback = nil
        lock.unlock()
    }

    /// Releases buffers and prevents any further writes. Safe to call from any thread.
    func dispose() {
        lock.lock()
        guard !_disposed else { lock.unlock(); return }
        _disposed = true
        callback = nil
        let b0 = buffers.0
        let b1 = buffers.1
        buffers = (nil, nil)
        lock.unlock()
        b0?.deallocate()
        b1?.deallocate()
    }

    func writeFrame(pixelBuffer: CVPixelBuffer, cameraId: Int) {
        // Bail out immediately if disposed, no lock held during memcpy below.
        lock.lock()
        if _disposed { lock.unlock(); return }
        let backIdx = 1 - frontIndex
        lock.unlock()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dataSize = bytesPerRow * height
        let totalSize = ImageStreamFFI.headerSize + dataSize

        // Resize back buffer if needed, hold lock for the pointer swap only.
        lock.lock()
        if _disposed { lock.unlock(); return }
        let backSize = backIdx == 0 ? bufferSizes.0 : bufferSizes.1
        var backBuf = backIdx == 0 ? buffers.0 : buffers.1
        if backSize < totalSize {
            let newBuf = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: 8)
            backBuf?.deallocate()
            backBuf = newBuf
            if backIdx == 0 {
                buffers.0 = newBuf
                bufferSizes.0 = totalSize
            } else {
                buffers.1 = newBuf
                bufferSizes.1 = totalSize
            }
        }
        lock.unlock()

        guard let buf = backBuf else { return }

        // Write to back buffer, no lock held during memcpy
        buf.storeBytes(of: Int32(0), toByteOffset: 24, as: Int32.self) // ready=0
        memcpy(buf.advanced(by: ImageStreamFFI.headerSize), baseAddress, dataSize)

        sequence += 1
        buf.storeBytes(of: sequence, toByteOffset: 0, as: Int64.self)
        buf.storeBytes(of: Int32(width), toByteOffset: 8, as: Int32.self)
        buf.storeBytes(of: Int32(height), toByteOffset: 12, as: Int32.self)
        buf.storeBytes(of: Int32(bytesPerRow), toByteOffset: 16, as: Int32.self)
        buf.storeBytes(of: Int32(0), toByteOffset: 20, as: Int32.self) // format=BGRA
        buf.storeBytes(of: Int32(1), toByteOffset: 24, as: Int32.self) // ready=1

        // Swap front/back and invoke callback (a native no-op symbol) under
        // the lock. Safe because the callback is a trivial C function.
        lock.lock()
        if _disposed { lock.unlock(); return }
        frontIndex = backIdx
        callback?(Int32(cameraId))
        lock.unlock()
    }

    deinit {
        dispose()
    }
}

/// Manages a single camera session, AVCaptureSession lifecycle, preview texture,
/// photo capture, video recording, and image streaming.
///
/// One CameraSession instance exists per active camera (identified by cameraId).
class CameraSession: NSObject {
    let cameraId: Int
    private(set) var textureId: Int64 = -1

    private let config: CameraConfig
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var texture: CameraTexture?
    private weak var textureRegistry: FlutterTextureRegistry?
    private weak var methodChannel: FlutterMethodChannel?

    private let captureQueue = DispatchQueue(label: "com.hugocornellier.camera_desktop.capture")
    private let audioQueue = DispatchQueue(label: "com.hugocornellier.camera_desktop.audio")
    private let sessionQueue = DispatchQueue(label: "com.hugocornellier.camera_desktop.session")
    private let bufferLock = UnfairLock()
    private let flagsLock = UnfairLock()

    private var lastTextureNotification: CFTimeInterval = 0
    private let textureNotificationInterval: CFTimeInterval = 1.0 / 120.0

    private var recordHandler = RecordHandler()
    private let imageStreamFFI = ImageStreamFFI()
    private var _previewPaused = false
    private var _imageStreaming = false
    private var _isDisposed = false
    private var latestBuffer: CVPixelBuffer?

    private var previewPaused: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _previewPaused }
        set { flagsLock.lock(); _previewPaused = newValue; flagsLock.unlock() }
    }

    private var imageStreaming: Bool {
        get { flagsLock.lock(); defer { flagsLock.unlock() }; return _imageStreaming }
        set { flagsLock.lock(); _imageStreaming = newValue; flagsLock.unlock() }
    }

    private var actualWidth: Int = 0
    private var actualHeight: Int = 0
    private var firstFrameReceived = false

    /// Pending initialization result callback, called when the first frame arrives.
    private var pendingInitResult: FlutterResult?

    struct CameraConfig {
        let deviceId: String
        let resolutionPreset: Int
        let enableAudio: Bool
        let targetFps: Int
        let targetBitrate: Int
        let audioBitrate: Int
    }

    init(cameraId: Int, config: CameraConfig,
         textureRegistry: FlutterTextureRegistry,
         methodChannel: FlutterMethodChannel) {
        self.cameraId = cameraId
        self.config = config
        self.textureRegistry = textureRegistry
        self.methodChannel = methodChannel
        super.init()
    }

    // MARK: - Texture Registration

    /// Registers a FlutterTexture and returns the texture ID.
    func registerTexture() -> Int64 {
        let tex = CameraTexture()
        texture = tex
        guard let registry = textureRegistry else { return -1 }
        textureId = registry.register(tex)
        return textureId
    }

    // MARK: - Initialization

    /// Initializes the AVCaptureSession. Responds asynchronously when the first frame arrives.
    func initialize(result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            print("[camera_desktop] Camera permission: \(granted ? "granted" : "denied")")
            if !granted {
                DispatchQueue.main.async {
                    result(FlutterError(code: "permission_denied",
                                        message: "Camera permission was denied",
                                        details: nil))
                }
                return
            }
            self.sessionQueue.async {
                self.setupSession(result: result)
            }
        }
    }

    private func setupSession(result: @escaping FlutterResult) {
        let session = AVCaptureSession()

        // Find the video device FIRST so we can validate preset support against it.
        let devices = AVCaptureDevice.captureDevices(mediaType: .video)
        print("[camera_desktop] Device selection: requested deviceId=\(config.deviceId), available=\(devices.map { $0.uniqueID })")
        let exactMatch = devices.first(where: { $0.uniqueID == config.deviceId })
        if exactMatch == nil {
            print("[camera_desktop] Exact device match not found for id=\(config.deviceId), falling back to first available device")
        }
        guard let device = exactMatch ?? devices.first else {
            DispatchQueue.main.async {
                result(FlutterError(code: "no_camera",
                                    message: "No camera device found for ID: \(self.config.deviceId)",
                                    details: nil))
            }
            return
        }
        print("[camera_desktop] Device selected: uniqueID=\(device.uniqueID) name=\(device.localizedName) (exactMatch=\(exactMatch != nil))")
        videoDevice = device
        print("[camera_desktop] Device found: uniqueID=\(device.uniqueID) deviceType=\(device.deviceType.rawValue) position=\(device.position.rawValue)")

        // Select preset based on what the device actually supports.
        let desiredPreset = DeviceEnumerator.sessionPreset(for: config.resolutionPreset)
        let fallbackPresets: [AVCaptureSession.Preset] = [.hd1920x1080, .hd1280x720, .high, .medium]
        var chosenPreset: AVCaptureSession.Preset = .medium
        var usedFallback = false
        if device.supportsSessionPreset(desiredPreset) && session.canSetSessionPreset(desiredPreset) {
            chosenPreset = desiredPreset
        } else {
            usedFallback = true
            print("[camera_desktop] Preset \(desiredPreset.rawValue) not supported by device, trying fallback")
            for fp in fallbackPresets {
                if device.supportsSessionPreset(fp) && session.canSetSessionPreset(fp) {
                    chosenPreset = fp
                    break
                }
            }
        }
        session.sessionPreset = chosenPreset
        print("[camera_desktop] Preset selected: \(chosenPreset.rawValue) (desired=\(desiredPreset.rawValue), usedFallback=\(usedFallback))")

        // Configure device.
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            // Non-fatal, continue with default settings.
            print("[camera_desktop] Device lockForConfiguration failed (non-fatal): \(error.localizedDescription)")
        }

        // Add video input.
        do {
            let videoInput = try AVCaptureDeviceInput(device: device)
            let canAdd = session.canAddInput(videoInput)
            print("[camera_desktop] canAddInput: \(canAdd)")
            guard canAdd else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "input_failed",
                                        message: "canAddInput returned false for device=\(device.uniqueID) preset=\(chosenPreset.rawValue) format=BGRA",
                                        details: nil))
                }
                return
            }
            session.addInput(videoInput)
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async {
                result(FlutterError(code: "input_failed",
                                    message: "Failed to create video input: \(message)",
                                    details: nil))
            }
            return
        }

        // Add audio input if enabled.
        if config.enableAudio {
            let audioDevices = AVCaptureDevice.captureDevices(mediaType: .audio)
            let audioDevice = audioDevices.first
            print("[camera_desktop] Audio device: \(audioDevice != nil ? audioDevice!.localizedName : "none found")")
            if let audioDevice = audioDevice {
                do {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if session.canAddInput(audioInput) {
                        session.addInput(audioInput)
                    }
                } catch {
                    // Non-fatal, continue without audio.
                    print("[camera_desktop] Failed to add audio input (non-fatal): \(error.localizedDescription)")
                }
            }
        }

        // Add video output.
        let vOutput = AVCaptureVideoDataOutput()
        vOutput.alwaysDiscardsLateVideoFrames = true
        vOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        vOutput.setSampleBufferDelegate(self, queue: captureQueue)
        let canAddOutput = session.canAddOutput(vOutput)
        print("[camera_desktop] canAddOutput: \(canAddOutput)")
        guard canAddOutput else {
            DispatchQueue.main.async {
                result(FlutterError(code: "output_failed",
                                    message: "canAddOutput returned false for device=\(device.uniqueID) preset=\(chosenPreset.rawValue) format=BGRA",
                                    details: nil))
            }
            return
        }
        session.addOutput(vOutput)
        videoOutput = vOutput

        // Mirror at the capture source so all consumers get mirrored frames.
        if let connection = vOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        } else {
            print("[camera_desktop] Video connection nil — mirroring not available for this output")
        }

        // Add audio output if enabled.
        if config.enableAudio {
            let aOutput = AVCaptureAudioDataOutput()
            aOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(aOutput) {
                session.addOutput(aOutput)
            }
            audioOutput = aOutput
        }

        // Subscribe to runtime error and interruption notifications.
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError,
                       object: session)
        nc.addObserver(self,
                       selector: #selector(sessionWasInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted,
                       object: session)
        nc.addObserver(self,
                       selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded,
                       object: session)

        let mirrorEnabled = vOutput.connection(with: .video)?.isVideoMirrored ?? false
        print("[camera_desktop] Session configured: \(chosenPreset.rawValue), mirror=\(mirrorEnabled), audio=\(config.enableAudio)")

        captureSession = session
        pendingInitResult = result
        firstFrameReceived = false

        // Start running, the first frame callback will respond to the pending result.
        session.startRunning()
        print("[camera_desktop] session.startRunning() called, isRunning=\(session.isRunning)")

        // Timeout: if no frame arrives in 15 seconds, fail.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self, let pending = self.pendingInitResult else { return }
            print("[camera_desktop] Initialization timeout fired, no frames received within 15s")
            self.pendingInitResult = nil
            pending(FlutterError(code: "initialization_timeout",
                                 message: "Camera initialization timed out, no frames received",
                                 details: nil))
        }
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        let message = error?.localizedDescription ?? "Unknown runtime error"
        print("[camera_desktop] AVCaptureSessionRuntimeError: \(message)")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.methodChannel?.invokeMethod("cameraError", arguments: [
                "cameraId": self.cameraId,
                "message": message,
            ])
        }
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        print("[camera_desktop] AVCaptureSessionWasInterrupted")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.methodChannel?.invokeMethod("cameraError", arguments: [
                "cameraId": self.cameraId,
                "message": "Camera session interrupted",
            ])
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        print("[camera_desktop] AVCaptureSessionInterruptionEnded — session recovering")
    }

    // MARK: - Photo Capture

    func takePicture(result: @escaping FlutterResult) {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()

        guard let buffer = buffer else {
            print("[camera_desktop] takePicture: latestBuffer is nil — no frames captured yet")
            result(FlutterError(code: "no_frame",
                                message: "No frame available for capture",
                                details: nil))
            return
        }

        let path = PhotoHandler.generatePath(cameraId: cameraId)
        print("[camera_desktop] takePicture: writing photo to path=\(path)")
        sessionQueue.async {
            let success = PhotoHandler.takePicture(from: buffer, outputPath: path)
            DispatchQueue.main.async {
                if success {
                    print("[camera_desktop] takePicture: write succeeded, path=\(path)")
                    result(path)
                } else {
                    print("[camera_desktop] takePicture: write failed for path=\(path)")
                    result(FlutterError(code: "capture_failed",
                                        message: "Failed to write JPEG to disk",
                                        details: nil))
                }
            }
        }
    }

    // MARK: - Video Recording

    func startVideoRecording(result: @escaping FlutterResult) {
        let enableAudio = config.enableAudio

        sessionQueue.async { [self] in
            do {
                let path = try self.recordHandler.startRecording(
                    width: self.actualWidth,
                    height: self.actualHeight,
                    targetFps: self.config.targetFps,
                    targetBitrate: self.config.targetBitrate,
                    audioBitrate: self.config.audioBitrate,
                    enableAudio: enableAudio
                )
                print("[camera_desktop] Recording started: path=\(path)")
                DispatchQueue.main.async { result(nil) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    result(FlutterError(code: "recording_failed",
                                        message: "Failed to start recording: \(message)",
                                        details: nil))
                }
            }
        }
    }

    func stopVideoRecording(result: @escaping FlutterResult) {
        guard recordHandler.isRecording else {
            result(FlutterError(code: "not_recording",
                                message: "No recording in progress",
                                details: nil))
            return
        }

        recordHandler.stopRecording { path in
            if let path = path {
                print("[camera_desktop] Recording stopped: path=\(path)")
            }
            DispatchQueue.main.async {
                if let path = path {
                    result(path)
                } else {
                    result(FlutterError(code: "recording_failed",
                                        message: "Failed to finalize recording",
                                        details: nil))
                }
            }
        }
    }

    // MARK: - Image Streaming

    func startImageStream() {
        print("[camera_desktop] startImageStream: cameraId=\(cameraId)")
        imageStreaming = true
    }

    func stopImageStream() {
        print("[camera_desktop] stopImageStream: cameraId=\(cameraId)")
        imageStreaming = false
    }

    // MARK: - FFI Image Stream Access

    func getImageStreamBufferPointer() -> UnsafeMutableRawPointer? {
        return imageStreamFFI.getBufferPointer()
    }

    func registerImageStreamCallback(_ callback: @convention(c) (Int32) -> Void) {
        imageStreamFFI.registerCallback(callback)
    }

    func unregisterImageStreamCallback() {
        imageStreamFFI.unregisterCallback()
    }

    // MARK: - Preview Control

    func pausePreview() {
        print("[camera_desktop] pausePreview: cameraId=\(cameraId)")
        previewPaused = true
    }

    func resumePreview() {
        print("[camera_desktop] resumePreview: cameraId=\(cameraId)")
        previewPaused = false
    }

    // MARK: - Mirror Control

    /// Toggles horizontal mirroring on the live video output connection.
    /// Can be called while the session is running, no restart needed.
    func setMirror(mirrored: Bool) {
        sessionQueue.async { [self] in
            guard let connection = self.videoOutput?.connection(with: .video) else {
                print("[camera_desktop] setMirror: video connection is nil, cannot set mirror=\(mirrored)")
                return
            }
            guard connection.isVideoMirroringSupported else {
                print("[camera_desktop] setMirror: connection does not support mirroring, ignoring mirror=\(mirrored)")
                return
            }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    // MARK: - Disposal

    /// Disposes the camera session. Safe to call multiple times (idempotent).
    ///
    /// Synchronously unregisters the FFI callback, stops image streaming, stops
    /// the AVCaptureSession (which blocks until all in-flight delegate calls
    /// complete), and tears down the session graph. After this method returns,
    /// the capture queue will not invoke any more callbacks.
    /// Texture unregistration and the cameraClosing event are dispatched to the
    /// main queue as they require UI-thread access.
    func dispose() {
        // Idempotency guard, first caller wins.
        flagsLock.lock()
        if _isDisposed { flagsLock.unlock(); return }
        _isDisposed = true
        _imageStreaming = false
        flagsLock.unlock()

        print("[camera_desktop] Camera session disposed")

        // Null out the FFI callback under lock, guarantees no in-flight
        // invocation reaches Dart after this returns.
        imageStreamFFI.unregisterCallback()

        // Remove notification observers before stopping the session.
        NotificationCenter.default.removeObserver(self)

        // stopRunning() blocks until all in-flight AVCaptureOutput delegate
        // calls have returned, so after this line captureOutput() cannot fire.
        recordHandler.stopRecording { _ in }
        captureSession?.stopRunning()
        captureSession = nil
        videoDevice = nil
        videoOutput = nil
        audioOutput = nil

        // UI cleanup must happen on the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.texture != nil, let registry = self.textureRegistry {
                registry.unregisterTexture(self.textureId)
            }
            self.texture = nil
            self.methodChannel?.invokeMethod("cameraClosing", arguments: ["cameraId": self.cameraId])
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate & AVCaptureAudioDataOutputSampleBufferDelegate

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        // Route audio buffers to the record handler.
        if output == audioOutput {
            recordHandler.appendAudioBuffer(sampleBuffer)
            return
        }

        // Video frame handling.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("[camera_desktop] captureOutput: CMSampleBufferGetImageBuffer returned nil — frame dropped")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Store the latest buffer for photo capture.
        bufferLock.lock()
        latestBuffer = pixelBuffer
        bufferLock.unlock()

        // Handle first-frame initialization response.
        let isFirstFrame = !firstFrameReceived
        if isFirstFrame {
            firstFrameReceived = true
            actualWidth = width
            actualHeight = height
            print("[camera_desktop] First frame received: width=\(width) height=\(height)")

            DispatchQueue.main.async { [weak self] in
                guard let self = self, let pending = self.pendingInitResult else { return }
                self.pendingInitResult = nil
                pending([
                    "previewWidth": Double(width),
                    "previewHeight": Double(height),
                ])
            }
        }

        // Update the texture for Flutter preview.
        if !previewPaused || isFirstFrame {
            texture?.update(buffer: pixelBuffer)
            let now = CACurrentMediaTime()
            if isFirstFrame || (now - lastTextureNotification) >= textureNotificationInterval {
                lastTextureNotification = now
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, let registry = self.textureRegistry else { return }
                    registry.textureFrameAvailable(self.textureId)
                }
            }
        }

        // Append to recording if active.
        recordHandler.appendVideoBuffer(sampleBuffer)

        // Send frame to Dart image stream if active.
        if imageStreaming {
            if imageStreamFFI.hasCallback {
                imageStreamFFI.writeFrame(pixelBuffer: pixelBuffer, cameraId: cameraId)
            } else {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
                guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let dataSize = bytesPerRow * height
                let data = Data(bytes: baseAddress, count: dataSize)
                let capturedBytesPerRow = bytesPerRow
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.methodChannel?.invokeMethod("imageStreamFrame", arguments: [
                        "cameraId": self.cameraId,
                        "width": width,
                        "height": height,
                        "bytesPerRow": capturedBytesPerRow,
                        "bytes": FlutterStandardTypedData(bytes: data),
                    ])
                }
            }
        }
    }
}
