import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Plays the Pi → Kinesis Video live HLS URL (expires after a few minutes).
class LiveKvsViewerScreen extends StatefulWidget {
  const LiveKvsViewerScreen({super.key, required this.hlsUrl});

  final String hlsUrl;

  @override
  State<LiveKvsViewerScreen> createState() => _LiveKvsViewerScreenState();
}

class _LiveKvsViewerScreenState extends State<LiveKvsViewerScreen> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initPlayer();
    });
  }

  Future<void> _initPlayer() async {
    try {
      final uri = Uri.parse(widget.hlsUrl);
      final video = VideoPlayerController.networkUrl(uri);
      await video.initialize();
      if (!mounted) {
        await video.dispose();
        return;
      }
      final primary = Theme.of(context).colorScheme.primary;
      final chewie = ChewieController(
        videoPlayerController: video,
        autoPlay: true,
        looping: true,
        allowFullScreen: true,
        showControls: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: primary,
          handleColor: primary,
          backgroundColor: Colors.grey,
          bufferedColor: Colors.grey.shade400,
        ),
      );
      setState(() {
        _video = video;
        _chewie = chewie;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _chewie?.dispose();
    _chewie = null;
    _video = null;
    await _initPlayer();
  }

  @override
  void dispose() {
    _chewie?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Open Camera'),
        actions: [
          IconButton(
            tooltip: 'Reload stream',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _reload,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Theme.of(context).colorScheme.error),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _reload,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : _chewie != null
                  ? Center(
                      child: AspectRatio(
                        aspectRatio: _video!.value.aspectRatio == 0
                            ? 16 / 9
                            : _video!.value.aspectRatio,
                        child: Chewie(controller: _chewie!),
                      ),
                    )
                  : const SizedBox.shrink(),
    );
  }
}
