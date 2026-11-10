// SPDX-License-Identifier: AGPL-3.0-or-later

package chat.fluffy.fluffychat;

import android.content.res.AssetManager;

import java.io.IOException;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

public final class VoiceTranscriptionChannel {
    private static final int MAX_BYTES = 16 * 1024 * 1024;
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();

    public static void register(BinaryMessenger messenger, AssetManager assets) {
        new MethodChannel(messenger, "chat.fluffy.fluffychat/voice_transcription")
                .setMethodCallHandler((call, result) -> {
                    if (!call.method.equals("transcribe")) {
                        result.notImplemented();
                        return;
                    }
                    if (!(call.arguments instanceof byte[])) {
                        result.error("voice_invalid", null, null);
                        return;
                    }
                    byte[] audio = (byte[]) call.arguments;
                    if (audio.length > MAX_BYTES) {
                        result.error("voice_too_long", null, null);
                        return;
                    }
                    WORKER.execute(() -> {
                        try {
                            AudioDecoder.Pcm pcm = AudioDecoder.decode(audio);
                            result.success(SenseVoice.recognize(assets, "voice_asr", pcm));
                        } catch (AudioDecoder.AudioTooLongException tooLong) {
                            result.error("voice_too_long", null, null);
                        } catch (InterruptedException cancelled) {
                            Thread.currentThread().interrupt();
                            result.error("voice_cancelled", null, null);
                        } catch (IOException | RuntimeException | LinkageError failure) {
                            result.error("voice_failed", null, null);
                        }
                    });
                });
    }
}
