import 'dart:async';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:camera_desktop/camera_desktop.dart';
import 'package:camera_desktop/src/image_stream_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraDesktopPlugin', () {
    late CameraDesktopPlugin plugin;
    late MethodChannel channel;
    final List<MethodCall> log = <MethodCall>[];

    setUp(() {
      channel = const MethodChannel('plugins.flutter.io/camera_desktop');
      plugin = CameraDesktopPlugin(channel: channel);
      log.clear();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            log.add(call);
            switch (call.method) {
              case 'availableCameras':
                return <Map<String, dynamic>>[
                  {
                    'name': 'Test Camera (/dev/video0)',
                    'lensDirection': 2,
                    'sensorOrientation': 0,
                  },
                ];
              case 'create':
                return {'cameraId': 1, 'textureId': 42};
              case 'initialize':
                return {'previewWidth': 1280.0, 'previewHeight': 720.0};
              case 'takePicture':
                return '/tmp/test.jpg';
              case 'startVideoRecording':
                return null;
              case 'stopVideoRecording':
                return {'path': '/tmp/test_video.mp4', 'framesDropped': 0};
              case 'startImageStream':
              case 'stopImageStream':
              case 'dispose':
              case 'pausePreview':
              case 'resumePreview':
                return null;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('registerWith sets CameraPlatform.instance', () {
      CameraDesktopPlugin.registerWith();
      expect(CameraPlatform.instance, isA<CameraDesktopPlugin>());
    });

    test('availableCameras returns camera list', () async {
      final cameras = await plugin.availableCameras();
      expect(cameras, hasLength(1));
      expect(cameras.first.name, contains('Test Camera'));
      expect(cameras.first.lensDirection, CameraLensDirection.external);
    });

    test('createCameraWithSettings returns cameraId', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      expect(cameraId, 1);
      expect(log.last.method, 'create');
    });

    test('initializeCamera fires CameraInitializedEvent', () async {
      // Create first so textureId mapping exists.
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      // Listen for the initialized event.
      final eventFuture = plugin.onCameraInitialized(cameraId).first;
      await plugin.initializeCamera(cameraId);
      final event = await eventFuture;

      expect(event.cameraId, cameraId);
      expect(event.previewWidth, 1280.0);
      expect(event.previewHeight, 720.0);
    });

    test('buildPreview returns Texture widget', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      final widget = plugin.buildPreview(cameraId);
      expect(widget, isA<Texture>());
    });

    test('takePicture returns XFile', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.initializeCamera(cameraId);

      final file = await plugin.takePicture(cameraId);
      expect(file.path, '/tmp/test.jpg');
    });

    test('dispose calls native dispose', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.dispose(cameraId);
      expect(log.last.method, 'dispose');
    });

    test('startVideoRecording calls native method', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.initializeCamera(cameraId);
      await plugin.startVideoRecording(cameraId);
      expect(log.last.method, 'startVideoRecording');
    });

    test('stopVideoRecording returns XFile', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );
      await plugin.initializeCamera(cameraId);
      await plugin.startVideoRecording(cameraId);
      final file = await plugin.stopVideoRecording(cameraId);
      expect(file.path, '/tmp/test_video.mp4');
    });

    test('supportsImageStreaming returns true', () {
      expect(plugin.supportsImageStreaming(), isTrue);
    });

    test('onStreamedFrameAvailable starts and stops stream', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      final stream = plugin.onStreamedFrameAvailable(cameraId);
      final subscription = stream.listen((_) {});
      // Starting the stream should have called startImageStream.
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'startImageStream');

      await subscription.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'stopImageStream');
    });

    test('setFlashMode off is no-op, others throw', () async {
      // FlashMode.off is silently accepted.
      await plugin.setFlashMode(1, FlashMode.off);
      // Non-off flash modes throw.
      expect(
        () => plugin.setFlashMode(1, FlashMode.torch),
        throwsA(isA<CameraException>()),
      );
    });

    test('setExposureMode auto is no-op, locked throws', () async {
      await plugin.setExposureMode(1, ExposureMode.auto);
      expect(
        () => plugin.setExposureMode(1, ExposureMode.locked),
        throwsA(isA<CameraException>()),
      );
    });

    test('setFocusMode auto is no-op, locked throws', () async {
      await plugin.setFocusMode(1, FocusMode.auto);
      expect(
        () => plugin.setFocusMode(1, FocusMode.locked),
        throwsA(isA<CameraException>()),
      );
    });

    test('unsupported methods throw CameraException', () async {
      expect(
        () => plugin.pauseVideoRecording(1),
        throwsA(isA<CameraException>()),
      );
    });

    test('zoom returns 1.0 bounds', () async {
      expect(await plugin.getMinZoomLevel(1), 1.0);
      expect(await plugin.getMaxZoomLevel(1), 1.0);
    });

    test('exposure offset returns 0.0', () async {
      expect(await plugin.getMinExposureOffset(1), 0.0);
      expect(await plugin.getMaxExposureOffset(1), 0.0);
      expect(await plugin.getExposureOffsetStepSize(1), 0.0);
    });

    test('imageStreamPollerFactory default is ImageStreamFfi.tryCreate', () {
      // Sanity: the seam defaults to the real FFI factory in production.
      expect(plugin.imageStreamPollerFactory(1), isNull); // null in tests
    });

    test('ImageStreamFfi.tryCreate returns null in test environment', () {
      // In the test environment, no native library is loaded, so FFI
      // symbol lookup should fail and tryCreate should return null.
      final ffi = ImageStreamFfi.tryCreate(1);
      expect(ffi, isNull);
    });

    test('dispose tears down an FFI stream whose subscription was never '
        'cancelled', () async {
      // Inject a fake poller so the FFI fast path is exercised without a
      // native library. Mirrors what happens on a real device when an app
      // disposes its CameraController without first calling stopImageStream().
      final fake = _FakeImageStreamPoller();
      plugin.imageStreamPollerFactory = (_) => fake;

      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      // Start streaming but DO NOT cancel the subscription.
      final subscription = plugin
          .onStreamedFrameAvailable(cameraId)
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(fake.started, isTrue, reason: 'poller should be started');
      expect(fake.stopped, isFalse);

      // Dispose the camera without cancelling the stream subscription.
      await plugin.dispose(cameraId);

      // The fix: dispose must tear the poller down so its timer does not leak.
      expect(
        fake.stopped,
        isTrue,
        reason: 'dispose must stop the orphaned poller',
      );
      expect(
        fake.disposed,
        isTrue,
        reason: 'dispose must dispose the orphaned poller',
      );

      await subscription.cancel();
    });

    test('onStreamedFrameAvailable uses MethodChannel fallback when FFI '
        'unavailable', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      // Start the image stream, should use MethodChannel fallback since
      // FFI symbols are not available in the test environment.
      final stream = plugin.onStreamedFrameAvailable(cameraId);
      final subscription = stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'startImageStream');

      await subscription.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'stopImageStream');
    });

    test('fallback frames are labelled BGRA and passed through unchanged, '
        'including row padding', () async {
      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      final frames = <CameraImageData>[];
      final subscription = plugin
          .onStreamedFrameAvailable(cameraId)
          .listen(frames.add);
      await Future<void>.delayed(Duration.zero);

      // 2x1 frame in BGRA order (a blue pixel, then a red one) with 4 bytes
      // of row padding, as macOS can deliver.
      final bytes = Uint8List.fromList(<int>[
        255, 0, 0, 255, //
        0, 0, 255, 255, //
        0, 0, 0, 0,
      ]);
      await _sendNativeCall(
        channel,
        MethodCall('imageStreamFrame', <String, Object>{
          'cameraId': cameraId,
          'width': 2,
          'height': 1,
          'bytesPerRow': 12,
          'bytes': bytes,
        }),
      );

      expect(frames, hasLength(1));
      final frame = frames.single;
      expect(frame.format.group, ImageFormatGroup.bgra8888);
      expect(frame.format.raw, 'BGRA');
      expect(frame.width, 2);
      expect(frame.height, 1);
      expect(frame.planes, hasLength(1));
      expect(frame.planes.single.bytes, bytes);
      expect(frame.planes.single.bytesPerRow, 12);
      expect(frame.planes.single.bytesPerPixel, 4);

      await subscription.cancel();
    });

    test(
      'fallback frames without bytesPerRow default to a tight stride',
      () async {
        const description = CameraDescription(
          name: 'Test Camera (/dev/video0)',
          lensDirection: CameraLensDirection.external,
          sensorOrientation: 0,
        );
        final cameraId = await plugin.createCameraWithSettings(
          description,
          const MediaSettings(resolutionPreset: ResolutionPreset.high),
        );

        final frames = <CameraImageData>[];
        final subscription = plugin
            .onStreamedFrameAvailable(cameraId)
            .listen(frames.add);
        await Future<void>.delayed(Duration.zero);

        await _sendNativeCall(
          channel,
          MethodCall('imageStreamFrame', <String, Object>{
            'cameraId': cameraId,
            'width': 3,
            'height': 2,
            'bytes': Uint8List(3 * 2 * 4),
          }),
        );

        expect(frames.single.planes.single.bytesPerRow, 12);
        expect(frames.single.format.raw, 'BGRA');

        await subscription.cancel();
      },
    );

    test('cancelling while startImageStream is in flight stops the stream '
        'with its real handle and never starts a poller', () async {
      final startCompleter = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            log.add(call);
            switch (call.method) {
              case 'create':
                return {'cameraId': 1, 'textureId': 42};
              case 'startImageStream':
                return startCompleter.future;
              default:
                return null;
            }
          });
      final fake = _FakeImageStreamPoller();
      var factoryCalls = 0;
      plugin.imageStreamPollerFactory = (_) {
        factoryCalls++;
        return fake;
      };

      const description = CameraDescription(
        name: 'Test Camera (/dev/video0)',
        lensDirection: CameraLensDirection.external,
        sensorOrientation: 0,
      );
      final cameraId = await plugin.createCameraWithSettings(
        description,
        const MediaSettings(resolutionPreset: ResolutionPreset.high),
      );

      final subscription = plugin
          .onStreamedFrameAvailable(cameraId)
          .listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(log.last.method, 'startImageStream');

      // Cancel before native has answered startImageStream.
      await subscription.cancel();
      expect(
        log.where((c) => c.method == 'stopImageStream'),
        isEmpty,
        reason: 'the stop must wait for the real stream handle',
      );

      startCompleter.complete(<String, Object>{'streamHandle': 7});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final stops = log.where((c) => c.method == 'stopImageStream').toList();
      expect(stops, hasLength(1));
      expect(
        (stops.single.arguments as Map<Object?, Object?>)['streamHandle'],
        7,
      );
      expect(factoryCalls, 0, reason: 'no poller may start after cancel');
      expect(fake.started, isFalse);
    });

    test(
      'cancelling after the stream started stops it with its real handle',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (MethodCall call) async {
              log.add(call);
              switch (call.method) {
                case 'create':
                  return {'cameraId': 1, 'textureId': 42};
                case 'startImageStream':
                  return <String, Object>{'streamHandle': 9};
                default:
                  return null;
              }
            });
        final fake = _FakeImageStreamPoller();
        plugin.imageStreamPollerFactory = (_) => fake;

        const description = CameraDescription(
          name: 'Test Camera (/dev/video0)',
          lensDirection: CameraLensDirection.external,
          sensorOrientation: 0,
        );
        final cameraId = await plugin.createCameraWithSettings(
          description,
          const MediaSettings(resolutionPreset: ResolutionPreset.high),
        );

        final subscription = plugin
            .onStreamedFrameAvailable(cameraId)
            .listen((_) {});
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(fake.started, isTrue);

        await subscription.cancel();

        final stops = log.where((c) => c.method == 'stopImageStream').toList();
        expect(stops, hasLength(1));
        expect(
          (stops.single.arguments as Map<Object?, Object?>)['streamHandle'],
          9,
        );
        expect(fake.stopped, isTrue);
        expect(fake.disposed, isTrue);
      },
    );
  });
}

/// Test double for [ImageStreamPoller] that records lifecycle calls.
class _FakeImageStreamPoller implements ImageStreamPoller {
  bool started = false;
  bool stopped = false;
  bool disposed = false;

  @override
  void start(StreamController<CameraImageData> controller) {
    started = true;
  }

  @override
  void stop() {
    stopped = true;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

/// Delivers [call] to the plugin as if the native side had invoked it.
Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(call),
        (_) {},
      );
}
