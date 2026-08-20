package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSRecommendItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSRecommendItem> CREATOR = new Parcelable.Creator<SSRecommendItem>() {
        @Override
        public SSRecommendItem createFromParcel(Parcel parcel) {
            return new SSRecommendItem(parcel);
        }

        @Override
        public SSRecommendItem[] newArray(int i10) {
            return new SSRecommendItem[i10];
        }
    };
    public final String backImageLink;
    public final String customJson;
    public final String description;
    public final String detailIconLink;
    public final String[] flags;

    public final int f10114id;
    public final boolean isNew;
    public final String listIconLink;
    public final String listNamingIconLink;
    public final String name;
    public final String payAid;
    public final int payAlertid;
    public final String putooTopicMid;
    public final String putooTopicName;
    public final String shareDesc;
    public final String shareImageLink;
    public final String shortDescription;
    public final String showIcon;
    public final String songListEffectIcon;
    public final long[] songListIds;
    public final String[] tags;
    public final boolean timeFree;
    public final int type;
    public final int vipType;

    public SSRecommendItem(int i10, int i11, String str, String[] strArr, String str2, String str3, String str4, String str5, String str6, long[] jArr, String str7, String str8, String str9, String[] strArr2, String str10, String str11, String str12, int i12, String str13, int i13, boolean z10, boolean z11, String str14, String str15) {
        this.f10114id = i10;
        this.type = i11;
        this.name = str;
        this.tags = strArr;
        this.listIconLink = str2;
        this.listNamingIconLink = str3;
        this.detailIconLink = str4;
        this.backImageLink = str5;
        this.description = str6;
        this.songListIds = jArr;
        this.shareImageLink = str7;
        this.shareDesc = str8;
        this.customJson = str9;
        this.flags = strArr2;
        this.showIcon = str12;
        this.vipType = i12;
        this.payAid = str13;
        this.payAlertid = i13;
        this.timeFree = z10;
        this.isNew = z11;
        this.putooTopicMid = str10;
        this.putooTopicName = str11;
        this.songListEffectIcon = str14;
        this.shortDescription = str15;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10114id);
        parcel.writeInt(this.type);
        parcel.writeString(this.name);
        parcel.writeStringArray(this.tags);
        parcel.writeString(this.listIconLink);
        parcel.writeString(this.listNamingIconLink);
        parcel.writeString(this.detailIconLink);
        parcel.writeString(this.backImageLink);
        parcel.writeString(this.description);
        parcel.writeLongArray(this.songListIds);
        parcel.writeString(this.shareImageLink);
        parcel.writeString(this.shareDesc);
        parcel.writeString(this.customJson);
        parcel.writeStringArray(this.flags);
        parcel.writeString(this.putooTopicMid);
        parcel.writeString(this.putooTopicName);
        parcel.writeString(this.showIcon);
        parcel.writeInt(this.vipType);
        parcel.writeString(this.payAid);
        parcel.writeInt(this.payAlertid);
        parcel.writeInt(this.timeFree ? 1 : 0);
        parcel.writeInt(this.isNew ? 1 : 0);
        parcel.writeString(this.songListEffectIcon);
        parcel.writeString(this.shortDescription);
    }

    protected SSRecommendItem(Parcel parcel) {
        this.f10114id = parcel.readInt();
        this.type = parcel.readInt();
        this.name = parcel.readString();
        this.tags = parcel.createStringArray();
        this.listIconLink = parcel.readString();
        this.listNamingIconLink = parcel.readString();
        this.detailIconLink = parcel.readString();
        this.backImageLink = parcel.readString();
        this.description = parcel.readString();
        this.songListIds = parcel.createLongArray();
        this.shareImageLink = parcel.readString();
        this.shareDesc = parcel.readString();
        this.customJson = parcel.readString();
        this.flags = parcel.createStringArray();
        this.putooTopicMid = parcel.readString();
        this.putooTopicName = parcel.readString();
        this.showIcon = parcel.readString();
        this.vipType = parcel.readInt();
        this.payAid = parcel.readString();
        this.payAlertid = parcel.readInt();
        this.timeFree = parcel.readInt() != 0;
        this.isNew = parcel.readInt() != 0;
        this.songListEffectIcon = parcel.readString();
        this.shortDescription = parcel.readString();
    }
}
