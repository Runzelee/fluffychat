// SPDX-License-Identifier: AGPL-3.0-or-later

package chat.fluffy.fluffychat;

import android.content.res.AssetManager;

import com.k2fsa.sherpa.onnx.OfflineModelConfig;
import com.k2fsa.sherpa.onnx.OfflineRecognizer;
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig;
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig;
import com.k2fsa.sherpa.onnx.OfflineStream;

final class SenseVoice {
    static String recognize(AssetManager assets, String modelDirectory, AudioDecoder.Pcm pcm) {
        OfflineSenseVoiceModelConfig senseVoice = new OfflineSenseVoiceModelConfig();
        senseVoice.setModel(modelDirectory + "/model.int8.onnx");
        senseVoice.setLanguage("auto");
        senseVoice.setUseInverseTextNormalization(true);

        OfflineModelConfig model = new OfflineModelConfig();
        model.setSenseVoice(senseVoice);
        model.setTokens(modelDirectory + "/tokens.txt");
        model.setNumThreads(2);
        model.setModelType("sense_voice");

        OfflineRecognizerConfig config = new OfflineRecognizerConfig();
        config.setModelConfig(model);

        OfflineRecognizer recognizer = new OfflineRecognizer(assets, config);
        try {
            OfflineStream stream = recognizer.createStream();
            try {
                stream.acceptWaveform(pcm.samples, pcm.sampleRate);
                recognizer.decode(stream);
                return recognizer.getResult(stream).getText().trim();
            } finally {
                stream.release();
            }
        } finally {
            recognizer.release();
        }
    }
}
