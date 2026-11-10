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

    Widget page(String key) => MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: VoiceTranscriptPanel(
          key: ValueKey(key),
          transcriptKey: key,
          color: Colors.black,
          builder: (toggle, transcript) => Column(
            children: [
              Row(children: [const Icon(Icons.mic_none), ?toggle]),
              ?transcript,
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(page(otherKey));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.expand_less), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);

    await tester.pumpWidget(page(transcriptKey));
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);

    expect(find.text('Hide transcript'), findsNothing);
    await tester.tap(find.byTooltip('Hide transcript'));
    await tester.pumpAndSettle();
    expect(find.text(text), findsNothing);
    expect(find.byType(Divider), findsNothing);
    expect(await service.read(transcriptKey), (text: text, expanded: false));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(page(transcriptKey));
    await tester.pumpAndSettle();
    expect(find.text(text), findsNothing);

    await tester.tap(find.byTooltip('Show transcript'));
    await tester.pumpAndSettle();
    expect(find.text(text), findsOneWidget);
    expect(await service.read(transcriptKey), (text: text, expanded: true));
  });
}
