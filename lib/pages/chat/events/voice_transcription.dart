// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:synchronized/synchronized.dart';

typedef VoiceTranscript = ({String text, bool expanded});

class VoiceTranscription {
  static final instance = VoiceTranscription();
  static const _storage = FlutterSecureStorage();
  static const _channel = MethodChannel(
    'chat.fluffy.fluffychat/voice_transcription',
  );
  static const _maxBytes = 16 * 1024 * 1024;
  static const _maxMilliseconds = 120 * 1000;

  final _running = <String, Future<void>>{};
  final _updates = StreamController<String>.broadcast();
  final _recognition = Lock();

  static bool supports(Event event) =>
      PlatformInfos.isAndroid &&
      event.status.isSent &&
      !event.redacted &&
      event.messageType == MessageTypes.Audio &&
      event.content.containsKey('org.matrix.msc3245.voice') &&
      event.room.client.userID != null;

  static String keyFor(Event event) {
    final identity = [event.room.client.userID, event.room.id, event.eventId];
    return 'voice-transcript.v1.${base64Url.encode(utf8.encode(jsonEncode(identity)))}';
  }

  bool isRunning(String key) => _running.containsKey(key);

  Stream<void> updatesFor(String key) =>
      _updates.stream.where((changed) => changed == key).map((_) {});

  Future<VoiceTranscript?> read(String key) async {
    final stored = await _storage.read(key: key);
    if (stored == null) return null;
    final record = jsonDecode(stored) as Map<String, dynamic>;
    return (
      text: record['text'] as String,
      expanded: record['expanded'] as bool,
    );
  }

  Future<void> write(String key, VoiceTranscript transcript) async {
    await _storage.write(
      key: key,
      value: jsonEncode({
        'text': transcript.text,
        'expanded': transcript.expanded,
      }),
    );
    _updates.add(key);
  }

  Future<void> transcribe(Event event) {
    final key = keyFor(event);
    return _running.putIfAbsent(key, () {
      _updates.add(key);
      return _recognition
          .synchronized(() => _transcribe(event, key))
          .whenComplete(() {
            _running.remove(key);
            _updates.add(key);
          });
    });
  }

  Future<void> _transcribe(Event event, String key) async {
    if (!event.room.client.isLogged() || keyFor(event) != key) return;
    final saved = await read(key);
    if (saved != null) {
      if (!saved.expanded) await write(key, (text: saved.text, expanded: true));
      return;
    }

    final info = event.content.tryGetMap<String, Object?>('info');
    if ((info?.tryGet<int>('size') ?? 0) > _maxBytes ||
        (info?.tryGet<int>('duration') ?? 0) > _maxMilliseconds) {
      throw PlatformException(code: 'voice_too_long');
    }
    final file = await event.downloadAndDecryptAttachment();
    if (file.bytes.length > _maxBytes) {
      throw PlatformException(code: 'voice_too_long');
    }

    final text = (await _channel.invokeMethod<String>(
      'transcribe',
      file.bytes,
    ))?.trim();
    if (text == null || text.isEmpty) {
      throw PlatformException(code: 'voice_empty');
    }
    if (!event.room.client.isLogged() ||
        !supports(event) ||
        keyFor(event) != key) {
      return;
    }
    await write(key, (text: text, expanded: true));
  }

  Future<void> transcribeWithFeedback(BuildContext context, Event event) async {
    try {
      await transcribe(event);
    } catch (error) {
      if (!context.mounted) return;
      final l10n = L10n.of(context);
      final message = switch (error) {
        PlatformException(code: 'voice_too_long') =>
          l10n.voiceTranscriptTooLong,
        PlatformException(code: 'voice_empty') => l10n.voiceTranscriptEmpty,
        _ => l10n.voiceTranscriptFailed,
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class VoiceTranscriptPanel extends StatefulWidget {
  final String transcriptKey;
  final Color color;

  const VoiceTranscriptPanel({
    required this.transcriptKey,
    required this.color,
    super.key,
  });

  @override
  State<VoiceTranscriptPanel> createState() => _VoiceTranscriptPanelState();
}

class _VoiceTranscriptPanelState extends State<VoiceTranscriptPanel> {
  final _service = VoiceTranscription.instance;
  late final StreamSubscription<void> _updates;
  VoiceTranscript? _transcript;
  int _readGeneration = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _updates = _service.updatesFor(widget.transcriptKey).listen((_) {
      setState(() {});
      unawaited(_reload());
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_updates.cancel());
    super.dispose();
  }

  Future<void> _reload() async {
    final generation = ++_readGeneration;
    try {
      final transcript = await _service.read(widget.transcriptKey);
      if (!mounted || generation != _readGeneration) return;
      setState(() => _transcript = transcript);
    } catch (_) {
      // A storage read failure must not interfere with playback.
    }
  }

  Future<void> _toggle(VoiceTranscript transcript) async {
    final next = (text: transcript.text, expanded: !transcript.expanded);
    setState(() => _saving = true);
    try {
      await _service.write(widget.transcriptKey, next);
      if (!mounted) return;
      ++_readGeneration;
      setState(() => _transcript = next);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).voiceTranscriptFailed)),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final transcript = _transcript;
    final busy = _service.isRunning(widget.transcriptKey);
    if (transcript == null && !busy) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(height: 1, color: widget.color.withValues(alpha: 0.25)),
          if (transcript == null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: widget.color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.voiceTranscribing,
                    style: TextStyle(color: widget.color),
                  ),
                ],
              ),
            )
          else ...[
            if (transcript.expanded)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  transcript.text,
                  style: TextStyle(color: widget.color),
                ),
              ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: widget.color),
              onPressed: _saving || busy ? null : () => _toggle(transcript),
              icon: Icon(
                transcript.expanded ? Icons.expand_less : Icons.expand_more,
              ),
              label: Text(
                transcript.expanded
                    ? l10n.voiceTranscriptCollapse
                    : l10n.voiceTranscriptExpand,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
