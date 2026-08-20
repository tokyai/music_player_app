package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSCustomItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCustomItem> CREATOR = new Parcelable.Creator<SSCustomItem>() {
        @Override
        public SSCustomItem createFromParcel(Parcel parcel) {
            return new SSCustomItem(parcel);
        }

        @Override
        public SSCustomItem[] newArray(int i10) {
            return new SSCustomItem[i10];
        }
    };
    public static int INVALID_ID = -1;
    public boolean bTemp;
    public String device;
    public float[] eqs;
    public float grainy;
    public float gullness;
    public float headDepth;
    public float headWidth;
    public String hrtfDataPath;
    public String hrtfServerID;

    public int f10105id;
    public float impact;
    public String name;
    public float precision;
    public float tightness;
    public String time;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10105id);
        parcel.writeString(this.name);
        parcel.writeString(this.device);
        parcel.writeString(this.time);
        parcel.writeFloat(this.impact);
        parcel.writeFloat(this.gullness);
        parcel.writeFloat(this.tightness);
        parcel.writeFloat(this.grainy);
        parcel.writeFloat(this.precision);
        parcel.writeFloatArray(this.eqs);
        parcel.writeFloat(this.headWidth);
        parcel.writeFloat(this.headDepth);
        parcel.writeString(this.hrtfServerID);
        parcel.writeString(this.hrtfDataPath);
        parcel.writeInt(this.bTemp ? 1 : 0);
    }

    public SSCustomItem(int i10, String str, String str2, String str3, float f10, float f11, float f12, float f13, float f14, float[] fArr, float f15, float f16, String str4, String str5, boolean z10) {
        this.f10105id = i10;
        this.name = str;
        this.device = str2;
        this.time = str3;
        this.impact = f10;
        this.gullness = f11;
        this.tightness = f12;
        this.grainy = f13;
        this.precision = f14;
        this.eqs = fArr;
        this.headWidth = f15;
        this.headDepth = f16;
        this.hrtfServerID = str4;
        this.hrtfDataPath = str5;
        this.bTemp = z10;
    }

    private SSCustomItem(Parcel parcel) {
        this.f10105id = parcel.readInt();
        this.name = parcel.readString();
        this.device = parcel.readString();
        this.time = parcel.readString();
        this.impact = parcel.readFloat();
        this.gullness = parcel.readFloat();
        this.tightness = parcel.readFloat();
        this.grainy = parcel.readFloat();
        this.precision = parcel.readFloat();
        this.eqs = parcel.createFloatArray();
        this.headWidth = parcel.readFloat();
        this.headDepth = parcel.readFloat();
        this.hrtfServerID = parcel.readString();
        this.hrtfDataPath = parcel.readString();
        this.bTemp = parcel.readInt() != 0;
    }
}
