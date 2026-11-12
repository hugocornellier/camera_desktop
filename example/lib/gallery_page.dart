import 'dart:io';

// material.dart is deprecated from Flutter 3.50 (package:material_ui replaces it).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

import 'photo_viewer_page.dart';
import 'recent_media.dart';
import 'video_player_page.dart';

class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key, required this.items});

  final List<MediaEntry> items;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Gallery (${items.length} of ${RecentMediaStore.maxItems})',
        ),
      ),
      body: Column(
        children: [
          _buildBanner(context),
          Expanded(
            child: items.isEmpty ? _buildEmptyState() : _buildGrid(context),
          ),
        ],
      ),
    );
  }

  Widget _buildBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(
            'STORES MOST RECENT ${RecentMediaStore.maxItems} ITEMS ONLY',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'No photos or videos yet',
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final crossAxisCount = width > 900
        ? 4
        : width > 600
        ? 3
        : 2;

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return GestureDetector(
          onTap: () => _onItemTap(context, item, index),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: item.isVideo
                ? _buildVideoThumbnail()
                : _buildPhotoThumbnail(item),
          ),
        );
      },
    );
  }

  void _onItemTap(BuildContext context, MediaEntry item, int index) {
    if (item.isVideo) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => VideoPlayerPage(path: item.path)),
      );
    } else {
      // Collect only photo entries and find the adjusted index.
      final photoItems = items.where((e) => e.isPhoto).toList();
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
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: Colors.grey.shade800),
        const Center(
          child: Icon(Icons.play_circle_fill, size: 48, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildPhotoThumbnail(MediaEntry item) {
    return Image.file(
      File(item.path),
      fit: BoxFit.cover,
      cacheWidth: 300,
      errorBuilder: (_, error, stackTrace) => Container(
        color: Colors.grey.shade200,
        child: const Icon(Icons.broken_image, color: Colors.grey),
      ),
    );
  }
}
