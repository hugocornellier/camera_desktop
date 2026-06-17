import AVFoundation

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
        let ptr = idx == 0 ? buffers.0 : buffers.1
        lock.unlock()
        return ptr
    }

    /// Total bytes currently held by the shared buffers.
    ///
    /// Diagnostic/test hook: lets callers assert that buffers are reclaimed
    /// after `releaseBuffers()` without measuring process-level memory.
    var allocatedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        let s0 = buffers.0 != nil ? bufferSizes.0 : 0
        let s1 = buffers.1 != nil ? bufferSizes.1 : 0
        return s0 + s1
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

    /// Frees both shared buffers without permanently disposing the instance.
    ///
    /// Unlike `dispose()`, the instance remains usable: a subsequent
    /// `writeFrame()` re-allocates lazily. Used to reclaim memory when image
    /// streaming stops but the camera session stays open.
    ///
    /// Thread-safety: the deallocation happens after the buffer pointers are
    /// nulled under the lock, so `getBufferPointer()` can never hand out a
    /// freed pointer. The caller is responsible for ensuring no `writeFrame()`
    /// is in flight (CameraSession serializes this onto the capture queue).
    func releaseBuffers() {
        lock.lock()
        guard !_disposed else { lock.unlock(); return }
        let b0 = buffers.0
        let b1 = buffers.1
        buffers = (nil, nil)
        bufferSizes = (0, 0)
        frontIndex = 0
        lock.unlock()
        b0?.deallocate()
        b1?.deallocate()
    }

    /// Releases the shared buffers and permanently disables further writes.
    ///
    /// Precondition: the caller MUST guarantee no `writeFrame()` is in flight.
    /// `writeFrame()` performs its `memcpy` without holding the lock, so freeing
    /// a buffer here concurrently with a write would be a use-after-free. This
    /// holds today because the sole caller is `deinit`, which only runs after
    /// the owning `CameraSession` has stopped the capture session — and
    /// `AVCaptureSession.stopRunning()` blocks until every in-flight
    /// `captureOutput`/`writeFrame` call has returned. It is therefore NOT safe
    /// to call from an arbitrary thread while capture is live.
    func dispose() {
        lock.lock()
        guard !_disposed else { lock.unlock(); return }
        _disposed = true
        callback = nil
        let b0 = buffers.0
        let b1 = buffers.1
        buffers = (nil, nil)
        bufferSizes = (0, 0)
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
