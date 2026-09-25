## 2.0.0

* **Breaking:** image stream frames on Linux and Windows are now BGRA, matching their reported `ImageFormatGroup.bgra8888`, macOS, and `camera` on iOS (#9). They were previously RGBA while still reported as `bgra8888` (only `format.raw` said `'RGBA'`), so code written for iOS/macOS saw red and blue swapped. **Migration:** remove any Linux/Windows RGBA workaround, such as choosing BGRA only when `Platform.isMacOS`, or `ChannelOrder.rgba` / `ChannelOrder.rgb` with `numChannels: 4` in `package:image`. Decode every desktop platform as BGRA (or, to support both 1.x and 2.x, treat the frame as RGBA only when `format.raw == 'RGBA'`), using `planes[0].bytesPerRow` as the row stride.
* Fix cancelling an image stream while `startImageStream` was still in flight: the stop was sent with the camera id in place of the real stream handle (which could release another stream's handle), and the FFI poller then started anyway and polled forever.
* Fix torn image stream frames: the FFI reader now re-checks the frame after copying and drops it if native code started overwriting the buffer mid-copy. Windows and Linux also add the missing memory fences around the shared buffer's ready flag.
* Fix Windows frames with a bottom-up (negative) `Lock2D` pitch being read in reverse row order, and make the plain `Lock` fallback honor the preview stream's stride instead of assuming tightly packed rows. The ARGB32 preview type now requests an explicit top-down stride instead of inheriting the camera-native format's.
* Cap MethodChannel fallback image-stream frames queued for the platform thread on Linux and Windows, so a stalled UI thread no longer accumulates unbounded frame copies.
* Document the image stream format and mirroring in the README.
* Add native pixel-helper unit tests (Linux and Windows) and a Linux CI job that streams from a v4l2loopback virtual camera and checks the bytes are really BGRA.

## 1.2.2

* Fix macOS ignoring the requested `ResolutionPreset`: frames and the preview always arrived at the camera's native format, 1920x1080 on a MacBook Pro camera, because macOS kept the device's active format whatever the session preset. The plugin now selects the smallest native format that covers the preset, holds it through session start, and asks the output for the preset's exact size: `low` 320x240, `medium` 640x480, `high` and `veryHigh` 1280x720, `ultraHigh` and `max` 1920x1080. Apps requesting `low`, `medium` or `high` on macOS now receive smaller frames than before.
* Fix the macOS FFI image-stream path never engaging: its entry points were private, so every macOS image stream silently fell back to the slower MethodChannel path. With the fast path active, the shared FFI buffers are now released in `stopImageStream` rather than only on dispose, and disposing a camera whose image stream is still subscribed no longer leaves its poll timer running.

## 1.2.1

* Fix Linux preview `Internal data stream error` (`not-negotiated`) on cameras that do not expose MJPEG, such as NV12/YUYV-only USB webcams. The MJPEG fast-path added in 1.1.7 was selected whenever its pipeline merely *parsed*, but `gst_parse_launch` succeeds even when the camera cannot produce MJPEG, so the intended raw-capture fallback never ran and initialization failed at `PLAYING`. The plugin now probes the V4L2 device (both `MJPEG` and `JPEG` pixel formats) for the target resolution before choosing the MJPEG path, and otherwise uses the always-safe raw capture path. The MJPEG pipeline pins only the resolution and lets the camera's native frame rate float, with `videorate` adapting it to the requested fps, so requesting a frame rate the camera does not expose natively in MJPEG no longer breaks negotiation. 

## 1.2.0

* Speed up Windows camera initialization by completing `initialize()` as soon as the preview starts instead of blocking until the first camera frame arrives. On a typical webcam this returns control to the app in roughly 250 ms rather than about 2 seconds. The preview fills in as frames arrive, and a watchdog reports a `cameraError` if no frames are received within 8 seconds.
* Make Windows diagnostic logging opt-in and off by default so the plugin stays quiet in your app. Set the `CAMERA_DESKTOP_LOG` environment variable to any value other than `0` to capture a trace when reporting an issue. This also removes the logging overhead that slowed camera initialization, most noticeably with a debugger or IDE attached.

## 1.1.8

* Fix Windows use-after-free crashes on camera dispose: guard the preview texture against in-flight preview samples, and defer destroying the texture until Flutter's asynchronous `UnregisterTexture` completes (its raster-thread pixel-buffer callback could otherwise run after the texture was freed) (#4)

## 1.1.7

* Fix Windows crash after camera dispose by marshalling platform channel messages to the platform thread (#4)
* Fix Linux preview `not-negotiated` error on common USB webcams (#5, thanks @jvnonce)
* Fix Linux recording on systems without `x264enc` (#5, thanks @jvnonce)
* Report max frame rate across all pixel formats during Linux device enumeration (#5, thanks @jvnonce)

## 1.1.6

* Fix Swift compiler warnings: remove unused variables in DeviceEnumerator, PhotoHandler, RecordHandler, and CameraSession

## 1.1.5

* Fix SPM integration by adding missing FlutterFramework dependency to iOS and macOS Package.swift

## 1.1.4

* Update documentation
* Remove debug logging from image stream pause/resume and video recording completion

## 1.1.3

* Fix Windows build failure (C4819 / C2220) on hosts with a non-UTF-8 system code page (e.g. CP936 on Simplified Chinese Windows) by compiling the plugin with `/utf-8` under MSVC (#2)

## 1.1.2

* Fix macOS build failure on Xcode 26+ by removing unavailable `AVCaptureSessionInterruptionReasonKey` (re-introduced in 1.1.1)
* Fix Windows build failure caused by implicit `wchar_t` to `char` conversion in debug logging

## 1.1.1

* Add comprehensive diagnostic logging across all platforms (Linux, macOS, Windows)
* Log device enumeration, backend selection, pipeline construction, resolution selection, recording lifecycle, and error paths

## 1.1.0

* Add PipeWire camera portal support for Flatpak sandbox compatibility on Linux
* Automatically detect Flatpak environment and use `pipewiresrc` instead of `v4l2src`
* Request camera access via `org.freedesktop.portal.Camera` D-Bus interface
* Enumerate PipeWire camera nodes via `GstDeviceMonitor`
* Fall back to V4L2 if portal is unavailable or user denies permission
* No new build dependencies: uses GIO (D-Bus) and GStreamer APIs already linked

## 1.0.8

* Fix macOS build failure on Xcode 26+ by removing unavailable `AVCaptureSessionInterruptionReasonKey` (iOS-only API)

## 1.0.7

* Fix camera initialization failure on Intel Macs by selecting session preset after device discovery using `device.supportsSessionPreset()` with automatic fallback (1080p → 720p → high → medium)
* Make `canAddInput`/`canAddOutput` failures return a `FlutterError` instead of silently skipping, preventing blank-screen timeouts
* Increase initialization timeout from 8s to 15s for slower USB cameras
* Subscribe to `AVCaptureSessionRuntimeError`, `WasInterrupted`, and `InterruptionEnded` notifications and forward to Dart via `cameraError`
* Fix MethodChannel image stream fallback sending hardcoded `bytesPerRow` instead of actual value from `CVPixelBuffer`
* Add diagnostic logging at all critical points in macOS session setup

## 1.0.6

* Fix Xcode build warnings by declaring PrivacyInfo.xcprivacy as a resource bundle in iOS and macOS podspecs

## 1.0.5

* Fixes #1: conflict with camera_android and camera_avfoundation dependencies

## 1.0.4

* Fix macOS Swift Package Manager compatibility

## 1.0.3

* Fix hot restart FFI crash by replacing NativeCallable with polling

## 1.0.2

* Fix macOS use-after-free crash during engine teardown by making dispose synchronous/idempotent and guarding FFI callbacks

## 1.0.1

* Fix xcprivacy build warnings by declaring resource_bundles in iOS and macOS podspecs

## 1.0.0

First stable release of `camera_desktop`

### Platform implementations

* **macOS**, AVFoundation (`AVCaptureSession`, `AVAssetWriter`). Preview via `CVPixelBuffer` textures, H.264/AAC recording, native mirror support.
* **Windows**, Media Foundation (`IMFCaptureEngine`) with Direct3D 11 texture rendering. H.264/AAC recording via `IMFSinkWriter`.
* **Linux**, GStreamer + V4L2 (`v4l2src → videoconvert → appsink` pipeline). H.264/AAC recording with automatic encoder selection, native mirror via `videoflip`.

### Features

* Live camera preview with hardware-accelerated texture rendering on all platforms
* Photo capture, video recording, and real-time image streaming
* FFI-based reduced-copy frame delivery (MethodChannel fallback for compatibility)
* Configurable resolution presets, FPS (5-60), and video bitrate
* Mirror/flip control (macOS and Linux)
* Pause/resume preview
* Runtime capability querying via `getPlatformCapabilities()`

## 0.0.8

* Migrate Windows implementation to IMFCaptureEngine

## 0.0.7

* Update example app to show settings panel

## 0.0.5

* Fix C linkage on Linux

## 0.0.4

* FFI-based image stream for reduced memory copies (3→2 per frame)
* Fix macOS Swift/ObjC interop for FFI bridge
* Fix image format reporting (Linux/Windows RGBA vs macOS BGRA)

## 0.0.3

* Performance improvements

## 0.0.2

* Add setMirror API and built-in camera sorting for DeviceEnumerator

## 0.0.1

* Linux camera support via GStreamer + V4L2.
* macOS camera support via AVFoundation.
* Windows camera support via Media Foundation.
* Full `camera_platform_interface` compliance.
* Photo capture, video recording, image streaming, and live preview.
