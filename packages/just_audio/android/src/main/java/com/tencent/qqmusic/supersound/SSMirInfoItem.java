package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSMirInfoItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSMirInfoItem> CREATOR = new Parcelable.Creator<SSMirInfoItem>() {
        @Override
        public SSMirInfoItem createFromParcel(Parcel parcel) {
            return new SSMirInfoItem(parcel);
        }

        @Override
        public SSMirInfoItem[] newArray(int i10) {
            return new SSMirInfoItem[i10];
        }
    };
    public float[] absPeaks;
    public int[] beatNum;
    public int beatPerSection;
    public float[] beatTime;
    public float bpm;
    public int chorusCount;
    public float[] chorusTimes;
    public int duration;
    public int partNotePerBeat;
    public float[] startTime;
    public String[] strChord;

    protected SSMirInfoItem(Parcel parcel) {
        this.bpm = parcel.readFloat();
        this.chorusTimes = parcel.createFloatArray();
        this.chorusCount = parcel.readInt();
        this.beatTime = parcel.createFloatArray();
        this.beatNum = parcel.createIntArray();
        this.startTime = parcel.createFloatArray();
        this.strChord = parcel.createStringArray();
        this.beatPerSection = parcel.readInt();
        this.partNotePerBeat = parcel.readInt();
        this.duration = parcel.readInt();
        this.absPeaks = parcel.createFloatArray();
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeFloat(this.bpm);
        parcel.writeFloatArray(this.chorusTimes);
        parcel.writeInt(this.chorusCount);
        parcel.writeFloatArray(this.beatTime);
        parcel.writeIntArray(this.beatNum);
        parcel.writeFloatArray(this.startTime);
        parcel.writeStringArray(this.strChord);
        parcel.writeInt(this.beatPerSection);
        parcel.writeInt(this.partNotePerBeat);
        parcel.writeInt(this.duration);
        parcel.writeFloatArray(this.absPeaks);
    }

    public SSMirInfoItem(float f10, float[] fArr, int i10, float[] fArr2, int[] iArr, float[] fArr3, String[] strArr, int i11, int i12, int i13, float[] fArr4) {
        this.bpm = f10;
        this.chorusTimes = fArr;
        this.chorusCount = i10;
        this.beatTime = fArr2;
        this.beatNum = iArr;
        this.startTime = fArr3;
        this.strChord = strArr;
        this.beatPerSection = i11;
        this.partNotePerBeat = i12;
        this.duration = i13;
        this.absPeaks = fArr4;
    }
}
