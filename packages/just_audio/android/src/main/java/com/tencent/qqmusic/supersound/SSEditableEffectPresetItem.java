package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;

public class SSEditableEffectPresetItem implements Parcelable {
    public static final Parcelable.Creator<SSEditableEffectPresetItem> CREATOR = new Parcelable.Creator<SSEditableEffectPresetItem>() {
        @Override
        public SSEditableEffectPresetItem createFromParcel(Parcel parcel) {
            return new SSEditableEffectPresetItem(parcel);
        }

        @Override
        public SSEditableEffectPresetItem[] newArray(int i10) {
            return new SSEditableEffectPresetItem[i10];
        }
    };
    public final SSEditableEffectPresetParamItem[] params;
    public final String presetDesc;
    public final String presetName;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.presetName);
        parcel.writeString(this.presetDesc);
        parcel.writeTypedArray(this.params, i10);
    }

    public SSEditableEffectPresetItem(String str, String str2, SSEditableEffectPresetParamItem[] sSEditableEffectPresetParamItemArr) {
        this.presetName = str;
        this.presetDesc = str2;
        this.params = sSEditableEffectPresetParamItemArr;
    }

    private SSEditableEffectPresetItem(Parcel parcel) {
        this.presetName = parcel.readString();
        this.presetDesc = parcel.readString();
        this.params = (SSEditableEffectPresetParamItem[]) parcel.createTypedArray(SSEditableEffectPresetParamItem.CREATOR);
    }
}
