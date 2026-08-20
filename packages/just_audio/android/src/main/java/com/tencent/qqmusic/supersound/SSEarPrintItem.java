package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSEarPrintItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSEarPrintItem> CREATOR = new Parcelable.Creator<SSEarPrintItem>() {
        @Override
        public SSEarPrintItem createFromParcel(Parcel parcel) {
            return new SSEarPrintItem(parcel);
        }

        @Override
        public SSEarPrintItem[] newArray(int i10) {
            return new SSEarPrintItem[i10];
        }
    };
    public final float[] eqs;
    public final float grainy;
    public final float gullness;

    public final int f10111id;
    public final float impact;
    public final String name;
    public final float precision;
    public final float tightness;
    public final int type;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10111id);
        parcel.writeInt(this.type);
        parcel.writeString(this.name);
        parcel.writeFloat(this.impact);
        parcel.writeFloat(this.gullness);
        parcel.writeFloat(this.tightness);
        parcel.writeFloat(this.grainy);
        parcel.writeFloat(this.precision);
        parcel.writeFloatArray(this.eqs);
    }

    public SSEarPrintItem(int i10, int i11, String str, float f10, float f11, float f12, float f13, float f14, float[] fArr) {
        this.f10111id = i10;
        this.type = i11;
        this.name = str;
        this.impact = f10;
        this.gullness = f11;
        this.tightness = f12;
        this.grainy = f13;
        this.precision = f14;
        this.eqs = fArr;
    }

    private SSEarPrintItem(Parcel parcel) {
        this.f10111id = parcel.readInt();
        this.type = parcel.readInt();
        this.name = parcel.readString();
        this.impact = parcel.readFloat();
        this.gullness = parcel.readFloat();
        this.tightness = parcel.readFloat();
        this.grainy = parcel.readFloat();
        this.precision = parcel.readFloat();
        this.eqs = parcel.createFloatArray();
    }
}
