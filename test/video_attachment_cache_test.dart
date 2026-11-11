// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fluffychat/utils/video_attachment_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _UnusedDatabase extends Fake implements DatabaseApi {}

class _VideoEvent extends Event {
  final Future<MatrixFile> Function(void Function(int)?) transfer;

  _VideoEvent(Room room, this.transfer)
    : super(
        room: room,
        eventId: r'$video:example.org',
        type: EventTypes.Message,
        senderId: '@sender:example.org',
        originServerTs: DateTime(2026),
        content: {
          'msgtype': MessageTypes.Video,
          'body': 'video.mp4',
          'url': 'mxc://example.org/video',
          'info': {'size': 4, 'mimetype': 'video/mp4'},
        },
      );

  @override
  Future<MatrixFile> downloadAndDecryptAttachment({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    bool skipScanner = false,
    void Function(int)? onDownloadProgress,
  }) => transfer(onDownloadProgress);
}

void main() {
  late Directory directory;
  late Client client;
  late Room room;
  late VideoAttachmentCache cache;
  final bytes = Uint8List.fromList([0, 1, 2, 3]);
  final video = MatrixFile(
    bytes: bytes,
    name: 'video.mp4',
    mimeType: 'video/mp4',
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluffy-video-test');
    client = Client('Video cache test', database: _UnusedDatabase())
      ..accessToken = 'test';
    room = Room(id: '!video:example.org', client: client);
    cache = VideoAttachmentCache(temporaryDirectory: () async => directory);
  });

  tearDown(() async {
    cache.dispose();
    await client.dispose(closeDatabase: false);
    await directory.delete(recursive: true);
  });

  test(
    'closing the viewer keeps the transfer and reopening uses disk',
    () async {
      final started = Completer<void>();
      final completed = Completer<MatrixFile>();
      var downloads = 0;
      Future<MatrixFile> transfer(void Function(int)? report) async {
        downloads++;
        report?.call(2);
        started.complete();
        return completed.future;
      }

      final event = _VideoEvent(room, transfer);
      final key = VideoAttachmentCache.keyFor(event);
      final releaseViewer = cache.retain(key);
      final pending = cache.load(event);
      await started.future;
      expect(cache.isTransferring(key), isTrue);
      expect(cache.progressOf(key), 0.5);

      releaseViewer();
      expect(cache.isTransferring(key), isTrue);
      final reopened = cache.load(_VideoEvent(room, transfer));
      expect(reopened, same(pending));
      completed.complete(video);

      final uri = await reopened;
      expect(cache.isTransferring(key), isFalse);
      expect(await File.fromUri(uri).readAsBytes(), bytes);

      final reopenedCache = VideoAttachmentCache(
        temporaryDirectory: () async => directory,
      );
      addTearDown(reopenedCache.dispose);
      expect(await reopenedCache.load(event), uri);
      expect(downloads, 1);
    },
  );

  test('a failed transfer clears progress and can be retried', () async {
    var attempts = 0;
    final event = _VideoEvent(room, (_) async {
      if (++attempts == 1) {
        throw const SocketException('connection interrupted');
      }
      return video;
    });

    await expectLater(cache.load(event), throwsA(isA<SocketException>()));
    expect(cache.isTransferring(VideoAttachmentCache.keyFor(event)), isFalse);
    expect(await File.fromUri(await cache.load(event)).readAsBytes(), bytes);
    expect(attempts, 2);
  });
}
