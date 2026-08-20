package com.tencent.qqmusic.supersound;

import java.io.Serializable;

public class SSAudioFeature implements Serializable {
    public static int ORG_SPECTRUM_BANDS = 1024;
    public static int TYPE_LOUDNESS = 1 << 1;
    public static int TYPE_SPECTRUM = 1;
    public float leftLoundess;
    public float[] leftSpectrumValues;
    public float rightLoudness;
    public float[] rightSpectrumValue;
    public int sampleRate;
    public int spectrumBands;
    public float[] spectrumFreqs;
    public long time;

    public SSAudioFeature(long j10, int i10, int i11, float[] fArr, float[] fArr2, float[] fArr3, float f10, float f11) {
        this.time = j10;
        this.sampleRate = i10;
        this.spectrumBands = i11;
        this.spectrumFreqs = fArr;
        this.leftSpectrumValues = fArr2;
        this.rightSpectrumValue = fArr3;
        this.leftLoundess = f10;
        this.rightLoudness = f11;
    }
}
