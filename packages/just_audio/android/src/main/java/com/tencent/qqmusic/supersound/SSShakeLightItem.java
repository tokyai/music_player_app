package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSShakeLightItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSShakeLightItem> CREATOR = new Parcelable.Creator<SSShakeLightItem>() {
        @Override
        public SSShakeLightItem createFromParcel(Parcel parcel) {
            return new SSShakeLightItem(parcel);
        }

        @Override
        public SSShakeLightItem[] newArray(int i10) {
            return new SSShakeLightItem[i10];
        }
    };
    public final String detailBackImage;
    public final String detailDesc;
    public final String detailIcon;

    public final int f10116id;
    public final String listIcon;
    public final String name;
    public final String shareDesc;
    public final String shareImage;
    public final long[] songListIds;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10116id);
        parcel.writeString(this.name);
        parcel.writeString(this.listIcon);
        parcel.writeString(this.detailIcon);
        parcel.writeString(this.detailBackImage);
        parcel.writeString(this.detailDesc);
        parcel.writeLongArray(this.songListIds);
        parcel.writeString(this.shareImage);
        parcel.writeString(this.shareDesc);
    }

    public SSShakeLightItem(int i10, String str, String str2, String str3, String str4, String str5, long[] jArr, String str6, String str7) {
        this.f10116id = i10;
        this.name = str;
        this.listIcon = str2;
        this.detailIcon = str3;
        this.detailBackImage = str4;
        this.detailDesc = str5;
        this.songListIds = jArr;
        this.shareImage = str6;
        this.shareDesc = str7;
    }

    private SSShakeLightItem(Parcel parcel) {
        this.f10116id = parcel.readInt();
        this.name = parcel.readString();
        this.listIcon = parcel.readString();
        this.detailIcon = parcel.readString();
        this.detailBackImage = parcel.readString();
        this.detailDesc = parcel.readString();
        this.songListIds = parcel.createLongArray();
        this.shareImage = parcel.readString();
        this.shareDesc = parcel.readString();
    }
}
