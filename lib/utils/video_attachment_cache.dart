// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Shares a video transfer across the chat and any viewer for that attachment.
class VideoAttachmentCache extends ChangeNotifier {
  static final instance = VideoAttachmentCache();

  static const _maxCacheBytes = 1024 * 1024 * 1024;
  static const _maxCacheAge = Duration(days: 30);

  final Future<Directory> Function() _temporaryDirectory;
  final _pending = <String, Future<Uri>>{};
  final _progress = <String, double?>{};
  final _viewers = <String, int>{};
  bool _pruning = false;

  VideoAttachmentCache({Future<Directory> Function()? temporaryDirectory})
    : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static String _accountPrefix(String clientName) => '${_hash(clientName)}-';

  static String keyFor(Event event) {
    final client = event.room.client;
    final encryptedFile = event.content.tryGetMap<String, Object?>('file');
    final id = _hash([
      client.userID,
      client.deviceID,
      client.homeserver?.toString(),
      event.room.id,
      event.eventId,
      event.attachmentMxcUrl?.toString(),
      encryptedFile?.tryGetMap<String, Object?>('hashes')?['sha256'],
      encryptedFile?.tryGetMap<String, Object?>('key')?['k'],
      encryptedFile?['iv'],
    ]);
    final filename = event.content.tryGet<String>('filename') ?? event.body;
    final filenameExtension = path.extension(filename).toLowerCase();
    final extension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(filenameExtension)
        ? filenameExtension
        : '.${extensionFromMime(event.attachmentMimetype) ?? 'mp4'}';
    return '${_accountPrefix(client.clientName)}$id$extension';
  }

  bool isTransferring(String key) => _progress.containsKey(key);

  double? progressOf(String key) => _progress[key];

  /// Keep the local file available while the player may still seek or replay.
  VoidCallback retain(String key) {
    _viewers.update(key, (count) => count + 1, ifAbsent: () => 1);
    return () {
      final count = _viewers[key]!;
      if (count == 1) {
        _viewers.remove(key);
      } else {
        _viewers[key] = count - 1;
      }
    };
  }

  Future<Uri> load(Event event) {
    final key = keyFor(event);
    return _pending.putIfAbsent(
      key,
      () => Future<Uri>.microtask(() => _load(event, key)),
    );
  }

  Future<Directory> _cacheDirectory() async => Directory(
    path.join((await _temporaryDirectory()).path, 'video-playback-v1'),
  );

  Future<Uri> _load(Event event, String key) async {
    try {
      final client = event.room.client;
      if (!client.isLogged()) throw StateError('Video session ended');
      final directory = kIsWeb ? null : await _cacheDirectory();
      final file = directory == null
          ? null
          : File(path.join(directory.path, key));
      if (file != null && (await file.stat()).size > 0) {
        await file.setLastModified(DateTime.now());
        return file.uri;
      }

      final size = event.infoMap.tryGet<int>('size') ?? 0;
      _setProgress(key, size > 0 ? 0 : null);
      final video = await event.downloadAndDecryptAttachment(
        onDownloadProgress: size <= 0
            ? null
            : (bytes) => _setProgress(
                key,
                bytes < size ? (bytes * 100 ~/ size) / 100 : null,
              ),
      );
      if (directory == null || file == null) {
        return Uri.dataFromBytes(video.bytes, mimeType: video.mimeType);
      }
      if (video.bytes.isEmpty) throw StateError('Video attachment is empty');

      final partial = File('${file.path}.partial');
      await directory.create(recursive: true);
      try {
        // A transfer can outlive the viewer, but must not recreate the cache
        // for an account that signed out while the download was in progress.
        void checkSession() {
          if (!client.isLogged() || keyFor(event) != key) {
            throw StateError('Video session ended');
          }
        }

        checkSession();
        await partial.writeAsBytes(video.bytes);
        checkSession();
        await partial.rename(file.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
      unawaited(_prune(directory));
      return file.uri;
    } finally {
      _pending.remove(key);
      if (_progress.containsKey(key)) {
        _progress.remove(key);
        notifyListeners();
      }
    }
  }

  void _setProgress(String key, double? value) {
    if (_progress.containsKey(key) && _progress[key] == value) return;
    _progress[key] = value;
    notifyListeners();
  }

  Future<void> _prune(Directory directory) async {
    if (_pruning) return;
    _pruning = true;
    try {
      final files = <({File file, FileStat stat})>[];
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File) continue;
        final stat = await entry.stat();
        if (stat.type == FileSystemEntityType.file) {
          files.add((file: entry, stat: stat));
        }
      }
      files.sort((a, b) => b.stat.modified.compareTo(a.stat.modified));
      final cutoff = DateTime.now().subtract(_maxCacheAge);
      var keptBytes = 0;
      for (final (:file, :stat) in files) {
        final key = path.basename(file.path);
        final active =
            _viewers.containsKey(key) ||
            _pending.containsKey(key) ||
            _pending.containsKey(key.replaceFirst(RegExp(r'\.partial$'), ''));
        if (active ||
            (keptBytes + stat.size <= _maxCacheBytes &&
                stat.modified.isAfter(cutoff))) {
          keptBytes += stat.size;
        } else {
          await file.delete();
        }
      }
    } on FileSystemException catch (error, stack) {
      Logs().w('Unable to trim the video cache', error, stack);
    } finally {
      _pruning = false;
    }
  }

  Future<void> clearAccount(String clientName) async {
    if (kIsWeb) return;
    final prefix = _accountPrefix(clientName);
    try {
      final directory = await _cacheDirectory();
      if (!await directory.exists()) return;
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && path.basename(entry.path).startsWith(prefix)) {
          await entry.delete();
        }
      }
    } catch (error, stack) {
      Logs().w('Unable to clear the video cache', error, stack);
    }
  }
}
