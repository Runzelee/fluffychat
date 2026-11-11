// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/video_attachment_cache.dart';
import 'package:fluffychat/widgets/blur_hash.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:video_player/video_player.dart';

import '../../widgets/mxc_image.dart';

class EventVideoPlayer extends StatefulWidget {
  final Event event;

  const EventVideoPlayer(this.event, {super.key});

  @override
  EventVideoPlayerState createState() => EventVideoPlayerState();
}

class EventVideoPlayerState extends State<EventVideoPlayer> {
  ChewieController? _chewieController;
  VideoPlayerController? _videoPlayerController;
  final _cache = VideoAttachmentCache.instance;
  late final _cacheKey = VideoAttachmentCache.keyFor(widget.event);
  late final VoidCallback _releaseCache;
  bool _failed = false;

  Future<void> _play() async {
    if (_failed) setState(() => _failed = false);
    try {
      final source = await _cache.load(widget.event);
      if (!mounted) return;
      final videoPlayerController = kIsWeb
          ? VideoPlayerController.networkUrl(source)
          : VideoPlayerController.file(File.fromUri(source));
      _videoPlayerController = videoPlayerController;

      await videoPlayerController.initialize();
      if (!mounted) return;

      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: videoPlayerController,
          showControlsOnInitialize: false,
          autoPlay: true,
          looping: true,
          aspectRatio: videoPlayerController.value.aspectRatio,
        );
      });
    } catch (e, s) {
      Logs().w('Unable to play video', e, s);
      if (!mounted) return;
      _disposeControllers();
      setState(() => _failed = true);
    }
  }

  void _disposeControllers() {
    _chewieController?.dispose();
    _videoPlayerController?.dispose();
    _chewieController = null;
    _videoPlayerController = null;
  }

  @override
  void dispose() {
    _disposeControllers();
    _releaseCache();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _releaseCache = _cache.retain(_cacheKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _play();
    });
  }

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  @override
  Widget build(BuildContext context) {
    final hasThumbnail = widget.event.hasThumbnail;
    final blurHash =
        (widget.event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final infoMap = widget.event.content.tryGetMap<String, Object?>('info');
    final videoWidth = infoMap?.tryGet<int>('w') ?? 400;
    final videoHeight = infoMap?.tryGet<int>('h') ?? 300;
    final height = MediaQuery.sizeOf(context).height - 52;
    final width = videoWidth * (height / videoHeight);

    final chewieController = _chewieController;
    return chewieController != null
        ? Center(
            child: SizedBox(
              width: width,
              height: height,
              child: Chewie(controller: chewieController),
            ),
          )
        : Stack(
            children: [
              Center(
                child: Hero(
                  tag: widget.event.eventId,
                  child: hasThumbnail
                      ? MxcImage(
                          event: widget.event,
                          isThumbnail: true,
                          width: width,
                          height: height,
                          fit: BoxFit.cover,
                          placeholder: (context) => BlurHash(
                            blurhash: blurHash,
                            width: width,
                            height: height,
                            fit: BoxFit.cover,
                          ),
                        )
                      : BlurHash(
                          blurhash: blurHash,
                          width: width,
                          height: height,
                        ),
                ),
              ),
              Center(
                child: _failed
                    ? FilledButton.icon(
                        onPressed: () {
                          if (_failed) _play();
                        },
                        icon: const Icon(Icons.refresh),
                        label: Text(L10n.of(context).tryAgain),
                      )
                    : ListenableBuilder(
                        listenable: _cache,
                        builder: (context, _) =>
                            CircularProgressIndicator.adaptive(
                              value: _cache.progressOf(_cacheKey),
                            ),
                      ),
              ),
            ],
          );
  }
}
