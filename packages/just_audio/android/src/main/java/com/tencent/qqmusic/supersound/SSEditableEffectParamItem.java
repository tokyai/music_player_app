package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;

public class SSEditableEffectParamItem implements Parcelable {
    public static final Parcelable.Creator<SSEditableEffectParamItem> CREATOR = new Parcelable.Creator<SSEditableEffectParamItem>() {
        @Override
        public SSEditableEffectParamItem createFromParcel(Parcel parcel) {
            return new SSEditableEffectParamItem(parcel);
        }

        @Override
        public SSEditableEffectParamItem[] newArray(int i10) {
            return new SSEditableEffectParamItem[i10];
        }
    };
    public final float defaultValue;
    public final int isStr;
    public final float maxValue;
    public final float minValue;
    public final String name;
    public final String str;
    public final int unit;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.name);
        parcel.writeInt(this.unit);
        parcel.writeInt(this.isStr);
        parcel.writeFloat(this.minValue);
        parcel.writeFloat(this.maxValue);
        parcel.writeFloat(this.defaultValue);
        parcel.writeString(this.str);
    }

    public SSEditableEffectParamItem(String str, int i10, int i11, float f10, float f11, float f12, String str2) {
        this.name = str;
        this.unit = i10;
        this.isStr = i11;
        this.minValue = f10;
        this.maxValue = f11;
        this.defaultValue = f12;
        this.str = str2;
    }

    private SSEditableEffectParamItem(Parcel parcel) {
        this.name = parcel.readString();
        this.unit = parcel.readInt();
        this.isStr = parcel.readInt();
        this.minValue = parcel.readFloat();
        this.maxValue = parcel.readFloat();
        this.defaultValue = parcel.readFloat();
        this.str = parcel.readString();
    }
}
