import 'dart:io';

// material.dart is deprecated from Flutter 3.50 (package:material_ui replaces it).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({super.key, required this.path});

  final String path;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _videoController;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);
    _focusNode = FocusNode();
    _player.open(Media(widget.path));
  }

  @override
  void dispose() {
    _player.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else if (event.logicalKey == LogicalKeyboardKey.space) {
      _player.playOrPause();
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final hours = d.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Video'),
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
      ),
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
          children: [
            Expanded(
              child: Platform.isWindows
                  ? Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(-1, 1, 1),
                      child: Video(
                        controller: _videoController,
                        fit: BoxFit.contain,
                      ),
                    )
                  : Video(controller: _videoController, fit: BoxFit.contain),
            ),
            _buildControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: _player.stream.playing,
            builder: (context, snap) {
              final playing = snap.data ?? false;
              return IconButton(
                icon: Icon(
                  playing ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                onPressed: _player.playOrPause,
              );
            },
          ),
          StreamBuilder<Duration>(
            stream: _player.stream.position,
            builder: (context, snap) {
              return Text(
                _formatDuration(snap.data ?? Duration.zero),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: _player.stream.duration,
              builder: (context, durSnap) {
                final duration = durSnap.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: _player.stream.position,
                  builder: (context, posSnap) {
                    final position = posSnap.data ?? Duration.zero;
                    return Slider(
                      value: duration.inMilliseconds > 0
                          ? position.inMilliseconds
                                .clamp(0, duration.inMilliseconds)
                                .toDouble()
                          : 0,
                      max: duration.inMilliseconds > 0
                          ? duration.inMilliseconds.toDouble()
                          : 1,
                      onChanged: (v) {
                        _player.seek(Duration(milliseconds: v.toInt()));
                      },
                      activeColor: Colors.white,
                      inactiveColor: Colors.white24,
                    );
                  },
                );
              },
            ),
          ),
          StreamBuilder<Duration>(
            stream: _player.stream.duration,
            builder: (context, snap) {
              return Text(
                _formatDuration(snap.data ?? Duration.zero),
                style: const TextStyle(color: Colors.white, fontSize: 12),
              );
            },
          ),
        ],
      ),
    );
  }
}
