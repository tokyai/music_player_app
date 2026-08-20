package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import androidx.annotation.NonNull;
import java.io.Serializable;

public class SSCreateCustomItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCreateCustomItem> CREATOR = new Parcelable.Creator<SSCreateCustomItem>() {
        @Override
        public SSCreateCustomItem createFromParcel(Parcel parcel) {
            return new SSCreateCustomItem(parcel);
        }

        @Override
        public SSCreateCustomItem[] newArray(int i10) {
            return new SSCreateCustomItem[i10];
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

    public int f10103id;
    public float impact;
    public String name;
    public float precision;
    public float tightness;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10103id);
        parcel.writeString(this.name);
        parcel.writeString(this.device);
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

    public SSCreateCustomItem(int i10, String str, String str2, float f10, float f11, float f12, float f13, float f14, float[] fArr, float f15, float f16, String str3, String str4, boolean z10) {
        this.f10103id = i10;
        this.name = str;
        this.device = str2;
        this.impact = f10;
        this.gullness = f11;
        this.tightness = f12;
        this.grainy = f13;
        this.precision = f14;
        this.eqs = fArr;
        this.headWidth = f15;
        this.headDepth = f16;
        this.hrtfServerID = str3;
        this.hrtfDataPath = str4;
        this.bTemp = z10;
    }

    public SSCreateCustomItem(@NonNull SSCustomItem sSCustomItem) {
        this.f10103id = sSCustomItem.f10105id;
        this.name = sSCustomItem.name;
        this.device = sSCustomItem.device;
        this.impact = sSCustomItem.impact;
        this.gullness = sSCustomItem.gullness;
        this.tightness = sSCustomItem.tightness;
        this.grainy = sSCustomItem.grainy;
        this.precision = sSCustomItem.precision;
        this.eqs = sSCustomItem.eqs;
        this.headWidth = sSCustomItem.headWidth;
        this.headDepth = sSCustomItem.headDepth;
        this.hrtfServerID = sSCustomItem.hrtfServerID;
        this.hrtfDataPath = sSCustomItem.hrtfDataPath;
        this.bTemp = sSCustomItem.bTemp;
    }

    public SSCreateCustomItem() {
        this.f10103id = INVALID_ID;
        this.name = "";
        this.device = "";
        this.impact = 0.0f;
        this.gullness = 0.0f;
        this.tightness = 0.0f;
        this.grainy = 0.0f;
        this.precision = 0.0f;
        this.eqs = new float[0];
        this.headWidth = 0.0f;
        this.headDepth = 0.0f;
        this.hrtfServerID = "";
        this.hrtfDataPath = "";
        this.bTemp = false;
    }

    private SSCreateCustomItem(Parcel parcel) {
        this.f10103id = parcel.readInt();
        this.name = parcel.readString();
        this.device = parcel.readString();
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
