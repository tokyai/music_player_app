package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSDeviceModelItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSDeviceModelItem> CREATOR = new Parcelable.Creator<SSDeviceModelItem>() {
        @Override
        public SSDeviceModelItem createFromParcel(Parcel parcel) {
            return new SSDeviceModelItem(parcel);
        }

        @Override
        public SSDeviceModelItem[] newArray(int i10) {
            return new SSDeviceModelItem[i10];
        }
    };
    public final int authType;
    public final String detailBackImage;
    public final String detailDesc;
    public final String detailIcon;
    public final int effectVipType;

    public final int f10108id;
    public final String name;
    public final String promoteImage;
    public final int promoteImageChroma;
    public final SSPromoteItem[] promoteItems;
    public final String putooTopicMid;
    public final String putooTopicName;
    public final String shareDesc;
    public final String shareImage;
    public final long[] songListIds;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10108id);
        parcel.writeString(this.name);
        parcel.writeString(this.promoteImage);
        parcel.writeString(this.detailIcon);
        parcel.writeString(this.detailBackImage);
        parcel.writeString(this.detailDesc);
        parcel.writeLongArray(this.songListIds);
        parcel.writeTypedArray(this.promoteItems, i10);
        parcel.writeString(this.shareImage);
        parcel.writeString(this.shareDesc);
        parcel.writeInt(this.promoteImageChroma);
        parcel.writeString(this.putooTopicMid);
        parcel.writeString(this.putooTopicName);
        parcel.writeInt(this.effectVipType);
        parcel.writeInt(this.authType);
    }

    public SSDeviceModelItem(int i10, String str, String str2, String str3, String str4, String str5, long[] jArr, SSPromoteItem[] sSPromoteItemArr, String str6, String str7, int i11, String str8, String str9, int i12, int i13) {
        this.f10108id = i10;
        this.name = str;
        this.promoteImage = str2;
        this.detailIcon = str3;
        this.detailBackImage = str4;
        this.detailDesc = str5;
        this.songListIds = jArr;
        this.promoteItems = sSPromoteItemArr;
        this.shareImage = str6;
        this.shareDesc = str7;
        this.promoteImageChroma = i11;
        this.putooTopicMid = str8;
        this.putooTopicName = str9;
        this.effectVipType = i12;
        this.authType = i13;
    }

    private SSDeviceModelItem(Parcel parcel) {
        this.f10108id = parcel.readInt();
        this.name = parcel.readString();
        this.promoteImage = parcel.readString();
        this.detailIcon = parcel.readString();
        this.detailBackImage = parcel.readString();
        this.detailDesc = parcel.readString();
        this.songListIds = parcel.createLongArray();
        this.promoteItems = (SSPromoteItem[]) parcel.createTypedArray(SSPromoteItem.CREATOR);
        this.shareImage = parcel.readString();
        this.shareDesc = parcel.readString();
        this.promoteImageChroma = parcel.readInt();
        this.putooTopicMid = parcel.readString();
        this.putooTopicName = parcel.readString();
        this.effectVipType = parcel.readInt();
        this.authType = parcel.readInt();
    }
}
