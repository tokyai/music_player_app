package com.ryanheise.just_audio.supersound;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;

import com.tencent.qqmusic.supersound.SuperSoundJni;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;

/** Media3 PCM processor that stays transparent whenever SuperSound cannot be used. */
final class SuperSoundAudioProcessor extends BaseAudioProcessor {
    private int sampleRate;
    private int channelCount;
    private long instance;
    private long appliedRevision = Long.MIN_VALUE;
    private long failedRevision = Long.MIN_VALUE;

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
            throws AudioProcessor.UnhandledAudioFormatException {
        sampleRate = inputAudioFormat.sampleRate;
        channelCount = inputAudioFormat.channelCount;
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            return AudioFormat.NOT_SET;
        }
        return inputAudioFormat;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        int inputBytes = inputBuffer.remaining();
        if (inputBytes == 0) {
            return;
        }
        int bytesPerFrame = channelCount * 2;
        SuperSoundController.EffectSelection selection =
                SuperSoundController.getDesiredEffect();
        if (selection.id <= 0 || !SuperSoundController.isReady()
                || sampleRate > 48000 || channelCount < 1 || channelCount > 2
                || inputBytes % bytesPerFrame != 0) {
            if (selection.id <= 0) {
                destroyInstance();
                appliedRevision = selection.revision;
            }
            copyThrough(inputBuffer, inputBytes);
            return;
        }

        if (!prepareEffect(selection)) {
            copyThrough(inputBuffer, inputBytes);
            return;
        }

        int shortCount = inputBytes / 2;
        int frameCount = inputBytes / bytesPerFrame;
        short[] original = new short[shortCount];
        ShortBuffer inputShorts = inputBuffer.duplicate()
                .order(ByteOrder.nativeOrder())
                .asShortBuffer();
        inputShorts.get(original);
        inputBuffer.position(inputBuffer.limit());
        short[] processed = original.clone();

        try {
            int[] availableFrames = new int[1];
            int inputResult = SuperSoundJni.supersound_process_in(
                    instance, processed, frameCount, availableFrames);
            if (inputResult != SuperSoundJni.ERR_SUPERSOUND_SUCCESS
                    || availableFrames[0] < 0) {
                failCurrentEffect(selection.revision);
                writeShorts(original, shortCount);
                return;
            }
            int requestedFrames = Math.min(frameCount, availableFrames[0]);
            int[] outputFrames = new int[1];
            int outputResult = SuperSoundJni.supersound_process_out(
                    instance, processed, requestedFrames, outputFrames);
            if (outputResult != SuperSoundJni.ERR_SUPERSOUND_SUCCESS
                    || outputFrames[0] < 0 || outputFrames[0] > requestedFrames) {
                failCurrentEffect(selection.revision);
                writeShorts(original, shortCount);
                return;
            }
            writeShorts(processed, outputFrames[0] * channelCount);
        } catch (Throwable error) {
            failCurrentEffect(selection.revision);
            writeShorts(original, shortCount);
        }
    }

    @Override
    protected void onFlush() {
        destroyInstance();
        appliedRevision = Long.MIN_VALUE;
        failedRevision = Long.MIN_VALUE;
    }

    @Override
    protected void onQueueEndOfStream() {
        if (instance == 0 || channelCount <= 0) {
            return;
        }
        try {
            SuperSoundJni.supersound_flush_out(instance);
            int cachedFrames = SuperSoundJni.supersound_get_cached_samples(instance);
            if (cachedFrames <= 0 || cachedFrames > sampleRate * 5) {
                return;
            }
            short[] tail = new short[cachedFrames * channelCount];
            int[] outputFrames = new int[1];
            int result = SuperSoundJni.supersound_process_out(
                    instance, tail, cachedFrames, outputFrames);
            if (result == SuperSoundJni.ERR_SUPERSOUND_SUCCESS
                    && outputFrames[0] > 0 && outputFrames[0] <= cachedFrames) {
                writeShorts(tail, outputFrames[0] * channelCount);
            }
        } catch (Throwable ignored) {
            // A failed drain only drops the DSP tail; playback remains healthy.
        }
    }

    @Override
    protected void onReset() {
        onFlush();
        sampleRate = 0;
        channelCount = 0;
    }

    private boolean prepareEffect(SuperSoundController.EffectSelection selection) {
        if (failedRevision == selection.revision) {
            return false;
        }
        if (instance == 0) {
            instance = SuperSoundController.createInstance(sampleRate, channelCount);
            if (instance == 0) {
                failedRevision = selection.revision;
                return false;
            }
            appliedRevision = Long.MIN_VALUE;
        }
        if (appliedRevision != selection.revision) {
            if (!SuperSoundController.applyEffect(
                    instance, selection.type, selection.id)) {
                failCurrentEffect(selection.revision);
                return false;
            }
            appliedRevision = selection.revision;
            failedRevision = Long.MIN_VALUE;
        }
        return true;
    }

    private void failCurrentEffect(long revision) {
        failedRevision = revision;
        destroyInstance();
    }

    private void destroyInstance() {
        SuperSoundController.destroyInstance(instance);
        instance = 0;
    }

    private void copyThrough(ByteBuffer inputBuffer, int byteCount) {
        ByteBuffer outputBuffer = replaceOutputBuffer(byteCount);
        outputBuffer.put(inputBuffer);
        outputBuffer.flip();
    }

    private void writeShorts(short[] samples, int shortCount) {
        ByteBuffer outputBuffer = replaceOutputBuffer(shortCount * 2);
        outputBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()
                .put(samples, 0, shortCount);
        outputBuffer.position(shortCount * 2);
        outputBuffer.flip();
    }
}
