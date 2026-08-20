package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;

public class SSEditableEffectPresetParamItem implements Parcelable {
    public static final Parcelable.Creator<SSEditableEffectPresetParamItem> CREATOR = new Parcelable.Creator<SSEditableEffectPresetParamItem>() {
        @Override
        public SSEditableEffectPresetParamItem createFromParcel(Parcel parcel) {
            return new SSEditableEffectPresetParamItem(parcel);
        }

        @Override
        public SSEditableEffectPresetParamItem[] newArray(int i10) {
            return new SSEditableEffectPresetParamItem[i10];
        }
    };
    public final int isStr;
    public final String name;
    public final String str;
    public final float value;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.name);
        parcel.writeInt(this.isStr);
        parcel.writeFloat(this.value);
        parcel.writeString(this.str);
    }

    public SSEditableEffectPresetParamItem(String str, int i10, float f10, String str2) {
        this.name = str;
        this.isStr = i10;
        this.value = f10;
        this.str = str2;
    }

    private SSEditableEffectPresetParamItem(Parcel parcel) {
        this.name = parcel.readString();
        this.isStr = parcel.readInt();
        this.value = parcel.readFloat();
        this.str = parcel.readString();
    }
}
