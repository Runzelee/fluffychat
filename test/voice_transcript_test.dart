// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/voice_transcription.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transcript and disclosure state survive leaving the message', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = VoiceTranscription.instance;
    const transcriptKey = 'first-account/room/voice';
    const otherKey = 'second-account/room/voice';
    const text = 'Persistent voice transcript';
    await service.write(transcriptKey, (text: text, expanded: true));
    expect(await service.read(otherKey), isNull);

    const page = MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: VoiceTranscriptPanel(
          transcriptKey: transcriptKey,
          color: Colors.black,
        ),
      ),
    );
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);

    await tester.tap(find.text('Hide transcript'));
    await tester.pumpAndSettle();
    expect(find.text(text), findsNothing);
    expect(await service.read(transcriptKey), (text: text, expanded: false));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page);
    await tester.pumpAndSettle();
    expect(find.text(text), findsNothing);

    await tester.tap(find.text('Show transcript'));
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);
    expect(await service.read(transcriptKey), (text: text, expanded: true));
  });
}
