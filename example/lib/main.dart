import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'gallery_page.dart';
import 'photo_viewer_page.dart';
import 'recent_media.dart';
import 'video_player_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const CameraExampleApp());
}

class CameraExampleApp extends StatelessWidget {
  const CameraExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera Desktop Example',
      // Workaround for an upstream Flutter Linux freeze (flutter/flutter#153560,
      // still open): the GTK/AT-SPI accessibility bridge blocks the UI thread on
      // a synchronous D-Bus call while walking the semantics tree when an
      // AT-SPI client is active (e.g. on settings changes here). Wrapping the
      // Navigator in ExcludeSemantics prunes the app's accessibility tree,
      // including overlay routes like dropdown popups, which avoids the hang.
      // Trade-off: in-app screen-reader support is disabled. Remove this once
      // the upstream bug is fixed if you need accessibility.
      builder: (context, child) => ExcludeSemantics(child: child!),
      home: const CameraExamplePage(),
    );
  }
}

enum CaptureMode { photo, video }

const List<int> kFpsOptions = [15, 24, 30, 60];

const List<({int value, String label})> kVideoBitrateOptions = [
  (value: 1000000, label: '1 Mbps'),
  (value: 2500000, label: '2.5 Mbps'),
  (value: 5000000, label: '5 Mbps'),
  (value: 10000000, label: '10 Mbps'),
  (value: 20000000, label: '20 Mbps'),
];

const List<({int value, String label})> kAudioBitrateOptions = [
  (value: 64000, label: '64 kbps'),
  (value: 128000, label: '128 kbps'),
  (value: 192000, label: '192 kbps'),
  (value: 256000, label: '256 kbps'),
];

class CameraExamplePage extends StatefulWidget {
  const CameraExamplePage({super.key});

  @override
  State<CameraExamplePage> createState() => _CameraExamplePageState();
}

class _CameraExamplePageState extends State<CameraExamplePage> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  String? _errorMessage;
  bool _isInitialized = false;
  bool _isCapturing = false;

  CaptureMode _mode = CaptureMode.photo;
  bool _isRecording = false;
  bool _isStoppingRecording = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  int _nextPendingVideoId = 1;
  final List<_PendingVideo> _pendingVideos = <_PendingVideo>[];

  // Settings state, these drive the CameraController constructor.
  int _selectedCameraIndex = 0;
  ResolutionPreset _resolutionPreset = ResolutionPreset.veryHigh;
  int _fps = 30;
  int _videoBitrate = 5000000;
  int _audioBitrate = 128000;
  bool _enableAudio = true;
  bool _showSettings = false;
  bool _isReinitializing = false;

  final RecentMediaStore _mediaStore = RecentMediaStore();

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _errorMessage = 'No cameras found');
        return;
      }
      await _createAndInitController();
    } on CameraException catch (e) {
      setState(() => _errorMessage = 'Camera error: ${e.description}');
    } catch (e) {
      setState(() => _errorMessage = 'Error: $e');
    }
  }

  Future<void> _createAndInitController() async {
    final controller = CameraController(
      _cameras[_selectedCameraIndex],
      _resolutionPreset,
      enableAudio: _enableAudio,
      fps: _fps,
      videoBitrate: _videoBitrate,
      audioBitrate: _audioBitrate,
    );

    await controller.initialize();
    if (!mounted) return;

    setState(() {
      _controller = controller;
      _isInitialized = true;
      _isReinitializing = false;
      _errorMessage = null;
    });
  }

  Future<void> _reinitCamera() async {
    if (_isRecording || _isStoppingRecording) return;

    setState(() {
      _isReinitializing = true;
      _isInitialized = false;
    });

    await _controller?.dispose();
    _controller = null;

    try {
      await _createAndInitController();
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _isReinitializing = false;
        _errorMessage = 'Camera error: ${e.description}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isReinitializing = false;
        _errorMessage = 'Error: $e';
      });
    }
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_isInitialized || _isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final file = await _controller!.takePicture();
      if (!mounted) return;
      _mediaStore.add(file.path, MediaType.photo);
      setState(() => _errorMessage = null);
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: ${e.description}')),
      );
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _startRecording() async {
    if (_controller == null || !_isInitialized || _isRecording) return;
    try {
      await _controller!.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() => _recordingDuration += const Duration(seconds: 1));
        }
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Recording failed: ${e.description}')),
      );
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording || _isStoppingRecording || _controller == null) return;
    _recordingTimer?.cancel();
    final pendingId = _nextPendingVideoId++;
    setState(() {
      _isRecording = false;
      _isStoppingRecording = true;
      _pendingVideos.insert(0, _PendingVideo(id: pendingId));
    });

    unawaited(_finalizeVideoStop(pendingId));
  }

  Future<void> _finalizeVideoStop(int pendingId) async {
    try {
      final file = await _controller!.stopVideoRecording();
      if (!mounted) return;
      _mediaStore.add(file.path, MediaType.video);
      setState(() {
        _isStoppingRecording = false;
        _pendingVideos.removeWhere((p) => p.id == pendingId);
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _isStoppingRecording = false;
        _pendingVideos.removeWhere((p) => p.id == pendingId);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Stop recording failed: ${e.description}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isStoppingRecording = false;
        _pendingVideos.removeWhere((p) => p.id == pendingId);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Stop recording failed: $e')));
    }
  }

  String _formatTimer(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _controller?.dispose();
    _mediaStore.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera Desktop Example'),
        actions: [
          IconButton(
            icon: Icon(
              _showSettings ? Icons.settings : Icons.settings_outlined,
            ),
            tooltip: 'Settings',
            onPressed: _isRecording
                ? null
                : () => setState(() => _showSettings = !_showSettings),
          ),
          IconButton(
            icon: Badge(
              label: Text('${_mediaStore.count + _pendingVideos.length}'),
              isLabelVisible:
                  _mediaStore.isNotEmpty || _pendingVideos.isNotEmpty,
              child: const Icon(Icons.photo_library),
            ),
            tooltip:
                'Gallery (${_mediaStore.count + _pendingVideos.length}/${RecentMediaStore.maxItems})',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => GalleryPage(items: _mediaStore.items),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildPreview()),
          if (_showSettings && _isInitialized) _buildSettingsPanel(),
          if (_isInitialized) _buildControlBar(),
          if (_mediaStore.isNotEmpty || _pendingVideos.isNotEmpty)
            _buildThumbnailStrip(),
          if (_errorMessage != null && !_isInitialized)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    if (_errorMessage != null && !_isInitialized && !_isReinitializing) {
      return Center(child: Text(_errorMessage!));
    }
    if (!_isInitialized || _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        Center(child: CameraPreview(_controller!)),
        if (_isRecording)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.fiber_manual_record,
                      color: Colors.red,
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'REC ${_formatTimer(_recordingDuration)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _resolutionLabel(ResolutionPreset preset) {
    return switch (preset) {
      ResolutionPreset.low => 'Low (240p)',
      ResolutionPreset.medium => 'Medium (480p)',
      ResolutionPreset.high => 'High (720p)',
      ResolutionPreset.veryHigh => 'Very High (1080p)',
      ResolutionPreset.ultraHigh => 'Ultra High (4K)',
      ResolutionPreset.max => 'Max',
    };
  }

  Widget _buildSettingsPanel() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          if (_cameras.length > 1)
            _buildDropdownSetting<int>(
              label: 'Camera',
              value: _selectedCameraIndex,
              items: [
                for (var i = 0; i < _cameras.length; i++)
                  DropdownMenuItem(value: i, child: Text(_cameras[i].name)),
              ],
              onChanged: (v) {
                if (v == null || v == _selectedCameraIndex) return;
                setState(() => _selectedCameraIndex = v);
                _reinitCamera();
              },
            ),
          _buildDropdownSetting<ResolutionPreset>(
            label: 'Resolution',
            value: _resolutionPreset,
            items: ResolutionPreset.values
                .map(
                  (p) => DropdownMenuItem(
                    value: p,
                    child: Text(_resolutionLabel(p)),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v == null || v == _resolutionPreset) return;
              setState(() => _resolutionPreset = v);
              _reinitCamera();
            },
          ),
          _buildDropdownSetting<int>(
            label: 'FPS',
            value: _fps,
            items: kFpsOptions
                .map((f) => DropdownMenuItem(value: f, child: Text('$f fps')))
                .toList(),
            onChanged: (v) {
              if (v == null || v == _fps) return;
              setState(() => _fps = v);
              _reinitCamera();
            },
          ),
          _buildDropdownSetting<int>(
            label: 'Video Bitrate',
            value: _videoBitrate,
            items: kVideoBitrateOptions
                .map(
                  (o) => DropdownMenuItem(value: o.value, child: Text(o.label)),
                )
                .toList(),
            onChanged: (v) {
              if (v == null || v == _videoBitrate) return;
              setState(() => _videoBitrate = v);
              _reinitCamera();
            },
          ),
          _buildDropdownSetting<int>(
            label: 'Audio Bitrate',
            value: _audioBitrate,
            items: kAudioBitrateOptions
                .map(
                  (o) => DropdownMenuItem(value: o.value, child: Text(o.label)),
                )
                .toList(),
            onChanged: (v) {
              if (v == null || v == _audioBitrate) return;
              setState(() => _audioBitrate = v);
              _reinitCamera();
            },
          ),
          _buildSwitchSetting(
            label: 'Audio',
            value: _enableAudio,
            onChanged: (v) {
              setState(() => _enableAudio = v);
              _reinitCamera();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownSetting<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
        DropdownButton<T>(
          value: value,
          items: items,
          onChanged: _isReinitializing ? null : onChanged,
          underline: const SizedBox.shrink(),
          isDense: true,
        ),
      ],
    );
  }

  Widget _buildSwitchSetting({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
        Switch(value: value, onChanged: _isReinitializing ? null : onChanged),
      ],
    );
  }

  Widget _buildControlBar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SegmentedButton<CaptureMode>(
            segments: const [
              ButtonSegment(
                value: CaptureMode.photo,
                icon: Icon(Icons.camera_alt),
              ),
              ButtonSegment(
                value: CaptureMode.video,
                icon: Icon(Icons.videocam),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: _isRecording
                ? null
                : (selection) => setState(() => _mode = selection.first),
          ),
          const SizedBox(width: 24),
          _buildCaptureButton(),
        ],
      ),
    );
  }

  Widget _buildCaptureButton() {
    if (_mode == CaptureMode.photo) {
      return FloatingActionButton(
        onPressed: _isCapturing ? null : _takePicture,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        child: _isCapturing
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.camera_alt),
      );
    }

    // Video mode
    if (_isRecording) {
      return FloatingActionButton(
        onPressed: _stopRecording,
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        child: const Icon(Icons.stop),
      );
    }

    return FloatingActionButton(
      onPressed: _isStoppingRecording ? null : _startRecording,
      backgroundColor: Colors.red,
      foregroundColor: Colors.white,
      child: _isStoppingRecording
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.fiber_manual_record),
    );
  }

  Widget _buildThumbnailStrip() {
    final items = _mediaStore.items;
    final pendingCount = _pendingVideos.length;
    return SizedBox(
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: pendingCount + items.length,
        itemBuilder: (context, index) {
          final isPending = index < pendingCount;
          final item = isPending ? null : items[index - pendingCount];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () {
                if (isPending) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Video is still processing. Please wait.'),
                    ),
                  );
                } else {
                  _onThumbnailTap(item!, index - pendingCount);
                }
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: isPending
                      ? _buildPendingVideoThumbnail()
                      : item!.isVideo
                      ? _buildVideoThumbnail()
                      : _buildPhotoThumbnail(item),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _onThumbnailTap(MediaEntry item, int index) {
    if (item.isVideo) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VideoPlayerPage(path: item.path)),
      );
    } else {
      final photoItems = _mediaStore.items.where((e) => e.isPhoto).toList();
      final photoIndex = photoItems.indexOf(item);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoViewerPage(
            items: photoItems,
            initialIndex: photoIndex >= 0 ? photoIndex : 0,
          ),
        ),
      );
    }
  }

  Widget _buildVideoThumbnail() {
    return Container(
      color: Colors.grey.shade800,
      child: const Center(
        child: Icon(Icons.play_circle_fill, size: 28, color: Colors.white70),
      ),
    );
  }

  Widget _buildPendingVideoThumbnail() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.grey.shade700),
        const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            color: Colors.black54,
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: const Text(
              'Processing',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 9),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoThumbnail(MediaEntry item) {
    return Image.file(
      File(item.path),
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      cacheWidth: 120,
      errorBuilder: (_, error, stackTrace) => Container(
        width: 64,
        height: 64,
        color: Colors.grey.shade300,
        child: const Icon(Icons.broken_image, size: 20),
      ),
    );
  }
}

class _PendingVideo {
  final int id;

  _PendingVideo({required this.id});
}
