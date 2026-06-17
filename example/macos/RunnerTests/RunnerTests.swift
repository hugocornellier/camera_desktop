import Cocoa
import FlutterMacOS
import XCTest
import AVFoundation
@testable import camera_desktop

class RunnerTests: XCTestCase {

  func testDeviceEnumeration() {
    // Should return a list (may be empty on CI/headless machines).
    let devices = DeviceEnumerator.enumerateDevices()
    XCTAssertNotNil(devices)
  }

  func testDeviceIdExtraction() {
    let name = "FaceTime HD Camera (0x1234567890)"
    let deviceId = DeviceEnumerator.extractDeviceId(from: name)
    XCTAssertEqual(deviceId, "0x1234567890")
  }

  func testDeviceIdExtractionNoParens() {
    let name = "NoParen"
    let deviceId = DeviceEnumerator.extractDeviceId(from: name)
    XCTAssertNil(deviceId)
  }

  func testDeviceIdExtractionNestedParens() {
    let name = "Camera (Model X) (ABC123)"
    let deviceId = DeviceEnumerator.extractDeviceId(from: name)
    XCTAssertEqual(deviceId, "ABC123")
  }

  func testSessionPresetMapping() {
    XCTAssertEqual(DeviceEnumerator.sessionPreset(for: 0), .low)
    XCTAssertEqual(DeviceEnumerator.sessionPreset(for: 1), .medium)
    XCTAssertEqual(DeviceEnumerator.sessionPreset(for: 2), .high)
    XCTAssertEqual(DeviceEnumerator.sessionPreset(for: 3), .hd1280x720)
    XCTAssertEqual(DeviceEnumerator.sessionPreset(for: 4), .hd1920x1080)
    XCTAssertEqual(DeviceEnumerator.sessionPreset(for: 5), .hd1920x1080)
  }

  func testPhotoPathGeneration() {
    let path = PhotoHandler.generatePath(cameraId: 42)
    XCTAssertTrue(path.contains("camera_desktop_42_"))
    XCTAssertTrue(path.hasSuffix(".jpg"))
  }

  func testRecordPathGeneration() {
    let path = RecordHandler.generatePath()
    XCTAssertTrue(path.contains("camera_desktop_video_"))
    XCTAssertTrue(path.hasSuffix(".mp4"))
  }

  /// Regression test for the image-stream buffer-release fix.
  ///
  /// Before the fix, stopping the image stream left both shared FFI buffers
  /// allocated until full session disposal. This asserts (deterministically,
  /// no camera or process-memory measurement required) that releaseBuffers()
  /// reclaims all buffer memory and that the instance stays reusable afterward.
  func testImageStreamBuffersReleasedOnStop() {
    let width = 640
    let height = 480

    var pb: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_32BGRA, [:] as CFDictionary, &pb)
    XCTAssertEqual(status, kCVReturnSuccess)
    guard let pixelBuffer = pb else {
      XCTFail("Failed to create test pixel buffer")
      return
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
      memset(base, 0x7F, bytesPerRow * height)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let perBuffer = ImageStreamFFI.headerSize + bytesPerRow * height

    let ffi = ImageStreamFFI()
    XCTAssertEqual(ffi.allocatedByteCount, 0, "starts with nothing allocated")

    ffi.writeFrame(pixelBuffer: pixelBuffer, cameraId: 1)
    ffi.writeFrame(pixelBuffer: pixelBuffer, cameraId: 1)
    XCTAssertEqual(ffi.allocatedByteCount, 2 * perBuffer,
                   "both shared buffers are allocated while streaming")
    XCTAssertNotNil(ffi.getBufferPointer(), "front buffer is readable while streaming")

    // The fix under test: stopping the stream reclaims all buffer memory.
    ffi.releaseBuffers()
    XCTAssertEqual(ffi.allocatedByteCount, 0, "releaseBuffers() reclaims all buffer memory")
    XCTAssertNil(ffi.getBufferPointer(), "no front buffer after release")

    // The instance remains usable: a later frame re-allocates lazily.
    ffi.writeFrame(pixelBuffer: pixelBuffer, cameraId: 1)
    XCTAssertEqual(ffi.allocatedByteCount, perBuffer,
                   "one buffer is re-allocated after release")
  }
}
