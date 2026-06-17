import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_desktop/src/image_stream_ffi.dart';

/// End-to-end proof for the orphaned-poller fix, using the REAL camera + real
/// FFI poller.
///
/// Scenario: an app starts an image stream and then disposes the camera WITHOUT
/// cancelling the stream subscription (exactly what `CameraController.dispose()`
/// does — it never stops image streams). Before the fix, the 8ms FFI poll timer
/// kept firing forever after the camera was gone. After the fix, `dispose()`
/// stops it.
///
/// We observe the real `ImageStreamFfi.pollCount` (number of poll ticks) before
/// and after `dispose()`: it must stop advancing.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'disposing a streaming camera stops the FFI poll timer (no leak)',
    (WidgetTester tester) async {
      final plugin = CameraPlatform.instance as CameraDesktopPlugin;

      // Capture the real FFI poller created for this stream (the default
      // factory is ImageStreamFfi.tryCreate, which succeeds in a real build).
      ImageStreamFfi? realPoller;
      final defaultFactory = plugin.imageStreamPollerFactory;
      plugin.imageStreamPollerFactory = (handle) {
        final poller = defaultFactory(handle);
        realPoller = poller as ImageStreamFfi?;
        return poller;
      };
      addTearDown(() => plugin.imageStreamPollerFactory = defaultFactory);

      final cameras = await plugin.availableCameras();
      // ignore: avoid_print
      print('[poller-leak-test] cameras found: ${cameras.length}');
      if (cameras.isEmpty) {
        markTestSkipped('No camera available on this machine.');
        return;
      }

      final cameraId = await plugin.createCameraWithSettings(
        cameras.first,
        const MediaSettings(resolutionPreset: ResolutionPreset.low),
      );

      try {
        await plugin.initializeCamera(cameraId);
      } on CameraException catch (e) {
        await plugin.dispose(cameraId);
        markTestSkipped('Camera initialize failed: ${e.code} ${e.description}');
        return;
      }

      // Start streaming. Critically: DO NOT cancel this subscription.
      final sub = plugin.onStreamedFrameAvailable(cameraId).listen((_) {});

      // Allow onListen (startImageStream round-trip) + several poll ticks.
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        realPoller,
        isNotNull,
        reason: 'FFI fast path should be active in a real macOS build',
      );
      final pollsWhileStreaming = realPoller!.pollCount;
      expect(
        pollsWhileStreaming,
        greaterThan(0),
        reason: 'the poll timer should be running while streaming',
      );

      // Dispose the camera WITHOUT cancelling the subscription — the leak path.
      await plugin.dispose(cameraId);

      final pollsAtDispose = realPoller!.pollCount;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final pollsAfterWait = realPoller!.pollCount;

      // ignore: avoid_print
      print(
        '[poller-leak-test] polls: whileStreaming=$pollsWhileStreaming '
        'atDispose=$pollsAtDispose afterWait(+600ms)=$pollsAfterWait',
      );

      expect(
        pollsAfterWait,
        equals(pollsAtDispose),
        reason: 'after dispose the poll timer MUST be stopped; before the fix '
            'it keeps firing ~125x/sec forever',
      );

      await sub.cancel();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
