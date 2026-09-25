import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:camera_desktop/camera_desktop.dart';

/// End-to-end check of the image stream pixel contract (issue #9), using the
/// real plugin and a real camera.
///
/// Every frame must be labelled `ImageFormatGroup.bgra8888` / `'BGRA'` and its
/// bytes must really be in B, G, R, A order. Both delivery paths are covered:
/// the FFI fast path (default) and the MethodChannel fallback (forced by
/// making the poller factory return null).
///
/// In CI the camera is a v4l2loopback device fed a solid red picture, and the
/// test runs with `--dart-define=EXPECT_RED_CAMERA=true`, which additionally
/// asserts that the red channel is the THIRD byte of each pixel. Without that
/// define (e.g. a laptop webcam) only the labels and layout are checked.
const bool _expectRedCamera = bool.fromEnvironment('EXPECT_RED_CAMERA');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final useFfi in <bool>[true, false]) {
    final path = useFfi ? 'FFI' : 'MethodChannel fallback';

    testWidgets('image stream frames are BGRA as labelled ($path)', (
      WidgetTester tester,
    ) async {
      final plugin = CameraPlatform.instance as CameraDesktopPlugin;

      var pollerCreated = false;
      final defaultFactory = plugin.imageStreamPollerFactory;
      plugin.imageStreamPollerFactory = (handle) {
        if (!useFfi) return null;
        final poller = defaultFactory(handle);
        pollerCreated = poller != null;
        return poller;
      };
      addTearDown(() => plugin.imageStreamPollerFactory = defaultFactory);

      final cameras = await plugin.availableCameras();
      // ignore: avoid_print
      print('[stream-format-test] cameras: ${cameras.map((c) => c.name)}');
      if (cameras.isEmpty) {
        if (_expectRedCamera) fail('EXPECT_RED_CAMERA set but no camera found');
        markTestSkipped('No camera available on this machine.');
        return;
      }

      final cameraId = await plugin.createCameraWithSettings(
        cameras.first,
        const MediaSettings(resolutionPreset: ResolutionPreset.low),
      );
      await plugin.initializeCamera(cameraId);

      // Skip the first few frames so any start-up frames are ignored.
      final frames = <CameraImageData>[];
      final gotFrames = Completer<void>();
      final sub = plugin.onStreamedFrameAvailable(cameraId).listen((frame) {
        frames.add(frame);
        if (frames.length == 5 && !gotFrames.isCompleted) gotFrames.complete();
      });

      try {
        await gotFrames.future.timeout(const Duration(seconds: 30));
      } finally {
        await sub.cancel();
        await plugin.dispose(cameraId);
      }

      if (useFfi) {
        expect(pollerCreated, isTrue, reason: 'FFI fast path should be used');
      }

      final frame = frames.last;
      final plane = frame.planes.single;

      expect(
        plane.bytes.length,
        greaterThanOrEqualTo(
          plane.bytesPerRow * (frame.height - 1) + frame.width * 4,
        ),
      );

      // Average each byte position over the centre 16x16 pixels.
      final sums = <int>[0, 0, 0, 0];
      var count = 0;
      final cx = frame.width ~/ 2, cy = frame.height ~/ 2;
      for (var y = cy - 8; y < cy + 8; y++) {
        for (var x = cx - 8; x < cx + 8; x++) {
          final i = y * plane.bytesPerRow + x * 4;
          for (var c = 0; c < 4; c++) {
            sums[c] += plane.bytes[i + c];
          }
          count++;
        }
      }
      final mean = sums.map((s) => s ~/ count).toList();
      // ignore: avoid_print
      print(
        '[stream-format-test] $path ${frame.width}x${frame.height} '
        'bytesPerRow=${plane.bytesPerRow} centre byte means '
        '[b0,b1,b2,b3]=$mean '
        'group=${frame.format.group} raw=${frame.format.raw}',
      );

      expect(frame.format.group, ImageFormatGroup.bgra8888);
      expect(frame.format.raw, 'BGRA');
      expect(plane.bytesPerPixel, 4);
      expect(plane.bytesPerRow, greaterThanOrEqualTo(frame.width * 4));

      if (_expectRedCamera) {
        expect(mean[0], lessThan(60), reason: 'byte 0 must be blue (low)');
        expect(mean[1], lessThan(60), reason: 'byte 1 must be green (low)');
        expect(mean[2], greaterThan(190), reason: 'byte 2 must be red (high)');
        expect(mean[3], 255, reason: 'byte 3 must be opaque alpha');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  }
}
