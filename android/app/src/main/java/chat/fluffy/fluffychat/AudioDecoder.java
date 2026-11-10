// SPDX-License-Identifier: AGPL-3.0-or-later

package chat.fluffy.fluffychat;

import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaDataSource;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.SystemClock;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

final class AudioDecoder {
    private static final int MAX_SECONDS = 120;
    private static final long TIMEOUT_MS = 10_000;

    static final class Pcm {
        final int sampleRate;
        final float[] samples;

        Pcm(int sampleRate, float[] samples) {
            this.sampleRate = sampleRate;
            this.samples = samples;
        }
    }

    static Pcm decode(byte[] audio) throws IOException, InterruptedException {
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(new BytesSource(audio));
            for (int track = 0; track < extractor.getTrackCount(); track++) {
                MediaFormat format = extractor.getTrackFormat(track);
                String mime = format.getString(MediaFormat.KEY_MIME);
                if (mime == null || !mime.startsWith("audio/")) continue;
                if (format.containsKey(MediaFormat.KEY_DURATION)
                        && format.getLong(MediaFormat.KEY_DURATION) > MAX_SECONDS * 1_000_000L) {
                    throw new AudioTooLongException();
                }
                extractor.selectTrack(track);
                MediaCodec codec = MediaCodec.createDecoderByType(mime);
                try {
                    codec.configure(format, null, null, 0);
                    codec.start();
                    return readPcm(codec, extractor);
                } finally {
                    codec.release();
                }
            }
            throw new IOException("Invalid or unsupported audio");
        } finally {
            extractor.release();
        }
    }

    private static Pcm readPcm(MediaCodec codec, MediaExtractor extractor)
            throws IOException, InterruptedException {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        boolean inputEnded = false;
        long lastProgress = SystemClock.elapsedRealtime();
        PcmBuffer pcm = null;
        while (true) {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
            if (!inputEnded) {
                int inputIndex = codec.dequeueInputBuffer(5_000);
                if (inputIndex >= 0) {
                    ByteBuffer input = codec.getInputBuffer(inputIndex);
                    if (input == null) throw new IOException("Invalid or unsupported audio");
                    input.clear();
                    int length = extractor.readSampleData(input, 0);
                    inputEnded = length < 0;
                    codec.queueInputBuffer(inputIndex, 0, Math.max(0, length),
                            inputEnded ? 0 : Math.max(0, extractor.getSampleTime()),
                            inputEnded ? MediaCodec.BUFFER_FLAG_END_OF_STREAM : 0);
                    if (!inputEnded) extractor.advance();
                    lastProgress = SystemClock.elapsedRealtime();
                }
            }
            int outputIndex = codec.dequeueOutputBuffer(info, 5_000);
            if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (pcm == null || pcm.size == 0) {
                    pcm = new PcmBuffer(codec.getOutputFormat());
                } else {
                    throw new IOException("Invalid or unsupported audio");
                }
                lastProgress = SystemClock.elapsedRealtime();
            } else if (outputIndex >= 0) {
                try {
                    if (info.size > 0 && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                        if (pcm == null) pcm = new PcmBuffer(codec.getOutputFormat(outputIndex));
                        ByteBuffer output = codec.getOutputBuffer(outputIndex);
                        if (output == null) throw new IOException("Invalid or unsupported audio");
                        output.limit(info.offset + info.size).position(info.offset);
                        pcm.add(output.order(ByteOrder.nativeOrder()));
                    }
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break;
                } finally {
                    codec.releaseOutputBuffer(outputIndex, false);
                }
                lastProgress = SystemClock.elapsedRealtime();
            }
            if (SystemClock.elapsedRealtime() - lastProgress > TIMEOUT_MS) {
                throw new IOException("Invalid or unsupported audio");
            }
        }
        if (pcm == null || pcm.size == 0) throw new IOException("Invalid or unsupported audio");
        return new Pcm(pcm.rate, Arrays.copyOf(pcm.samples, pcm.size));
    }

    static final class AudioTooLongException extends IOException {}

    private static final class PcmBuffer {
        final int rate;
        final int channels;
        final boolean floating;
        final int frameSize;
        final int limit;
        float[] samples = new float[4096];
        int size;

        PcmBuffer(MediaFormat format) throws IOException {
            rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
            channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
            int encoding = format.containsKey(MediaFormat.KEY_PCM_ENCODING)
                    ? format.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    : AudioFormat.ENCODING_PCM_16BIT;
            floating = encoding == AudioFormat.ENCODING_PCM_FLOAT;
            if (rate < 4000 || rate > 96000 || channels < 1 || channels > 8
                    || (!floating && encoding != AudioFormat.ENCODING_PCM_16BIT)) {
                throw new IOException("Invalid or unsupported audio");
            }
            frameSize = channels * (floating ? Float.BYTES : Short.BYTES);
            limit = rate * MAX_SECONDS;
        }

        void add(ByteBuffer input) throws IOException {
            int frames = input.remaining() / frameSize;
            if (input.remaining() % frameSize != 0) throw new IOException("Invalid or unsupported audio");
            int end = size + frames;
            if (end > limit) throw new AudioTooLongException();
            if (end > samples.length) {
                samples = Arrays.copyOf(samples, Math.min(limit, Math.max(end, samples.length * 2)));
            }
            while (size < end) {
                float sum = 0;
                for (int channel = 0; channel < channels; channel++) {
                    sum += floating ? input.getFloat() : input.getShort() / 32768f;
                }
                samples[size++] = sum / channels;
            }
        }
    }

    private static final class BytesSource extends MediaDataSource {
        private final byte[] audio;

        BytesSource(byte[] audio) {
            this.audio = audio;
        }

        @Override
        public int readAt(long position, byte[] buffer, int offset, int size) {
            if (size == 0) return 0;
            if (position < 0 || position >= audio.length) return -1;
            int count = Math.min(size, audio.length - (int) position);
            System.arraycopy(audio, (int) position, buffer, offset, count);
            return count;
        }

        @Override
        public long getSize() {
            return audio.length;
        }

        @Override
        public void close() {
            // This source owns no file descriptor.
        }
    }
}
