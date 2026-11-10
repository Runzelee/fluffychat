# FluffyChat Voice

An Android ARM64 fork of FluffyChat 2.11.5. Long-press a voice bubble and choose
**Transcribe**. The result appears below the waveform. Tap **Hide transcript**
or **Show transcript** to change its visibility, and select the text to copy it.
Long-press still offers **Download file** and **Select**.

The Matrix client fetches and decrypts the audio. Android decodes it locally,
and the bundled SenseVoice INT8 model converts it to text. Transcripts and
visibility are saved in Android secure storage by account, room, and event.
They persist across app restarts and upgrades, and clearing app data removes
them. The app does not sync transcripts to the homeserver or other devices.
Transcription accepts Matrix voice messages up to 2 minutes and 16 MiB.

## Build

Use Flutter 3.47.9, Android SDK 37, the Flutter Android NDK, and Rust as required
by upstream. For the release build, set up `android/key.properties` with a
dedicated signing key. Keep the same key for future updates.

```sh
./scripts/prepare-voice-transcription.sh
flutter pub get
flutter build apk --release --target-platform android-arm64
```

The preparation script verifies the model, runtime and third-party notices by
SHA-256. It puts the downloaded dependencies under the ignored
`.voice-engine/` directory. Set `VOICE_ENGINE_CACHE` to reuse existing
downloads.

The package name is `chat.fluffy.fluffychat.voice` for side-by-side installation.
Log in to Matrix separately. Self-built packages use UnifiedPush for push
delivery. The official Firebase configuration is specific to the official app.
