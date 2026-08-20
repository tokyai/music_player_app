package com.ryanheise.just_audio.supersound;

import android.content.Context;

import androidx.annotation.Nullable;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;

/** Installs SuperSound before Media3's normal silence and speed processors. */
public final class SuperSoundRenderersFactory extends DefaultRenderersFactory {
    public SuperSoundRenderersFactory(Context context) {
        super(context);
    }

    @Override
    @Nullable
    protected AudioSink buildAudioSink(
            Context context,
            boolean enableFloatOutput,
            boolean enableAudioOutputPlaybackParameters) {
        return new DefaultAudioSink.Builder(context)
                .setAudioProcessors(new AudioProcessor[]{new SuperSoundAudioProcessor()})
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParameters)
                .build();
    }
}
