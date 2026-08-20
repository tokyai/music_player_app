package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSFocusMapItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSFocusMapItem> CREATOR = new Parcelable.Creator<SSFocusMapItem>() {
        @Override
        public SSFocusMapItem createFromParcel(Parcel parcel) {
            return new SSFocusMapItem(parcel);
        }

        @Override
        public SSFocusMapItem[] newArray(int i10) {
            return new SSFocusMapItem[i10];
        }
    };
    public final int audioEffectId;
    public final int audioEffectType;
    public final String extraParams;
    public final int isAdvertisement;
    public final String promoteImage;
    public final String promoteScheme;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.promoteScheme);
        parcel.writeString(this.promoteImage);
        parcel.writeInt(this.audioEffectType);
        parcel.writeInt(this.audioEffectId);
        parcel.writeInt(this.isAdvertisement);
        parcel.writeString(this.extraParams);
    }

    public SSFocusMapItem(String str, String str2, int i10, int i11, int i12, String str3) {
        this.promoteScheme = str;
        this.promoteImage = str2;
        this.audioEffectType = i10;
        this.audioEffectId = i11;
        this.isAdvertisement = i12;
        this.extraParams = str3;
    }

    private SSFocusMapItem(Parcel parcel) {
        this.promoteScheme = parcel.readString();
        this.promoteImage = parcel.readString();
        this.audioEffectType = parcel.readInt();
        this.audioEffectId = parcel.readInt();
        this.isAdvertisement = parcel.readInt();
        this.extraParams = parcel.readString();
    }
}
