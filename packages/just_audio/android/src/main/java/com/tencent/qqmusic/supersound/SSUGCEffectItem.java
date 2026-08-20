package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSUGCEffectItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSUGCEffectItem> CREATOR = new Parcelable.Creator<SSUGCEffectItem>() {
        @Override
        public SSUGCEffectItem createFromParcel(Parcel parcel) {
            return new SSUGCEffectItem(parcel);
        }

        @Override
        public SSUGCEffectItem[] newArray(int i10) {
            return new SSUGCEffectItem[i10];
        }
    };
    public final String authorUin;
    public final String detailBackImage;
    public final String detailDesc;
    public final String detailIcon;
    public final String downloadLink;
    public final String effectPackageMd5;
    public final int effectPackageSize;

    public final int f10120id;
    public final int isDJEffect;
    public final int isNew;
    public final int isRecommend;
    public final String listIcon;
    public final String name;
    public final String publishTime;
    public final String putooTopicMid;
    public final String putooTopicName;
    public final String shareImage;
    public final String shortDescription;
    public final String songListEffectIcon;
    public final String[] tags;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10120id);
        parcel.writeString(this.name);
        parcel.writeString(this.authorUin);
        parcel.writeStringArray(this.tags);
        parcel.writeString(this.detailDesc);
        parcel.writeString(this.downloadLink);
        parcel.writeString(this.listIcon);
        parcel.writeString(this.detailIcon);
        parcel.writeString(this.detailBackImage);
        parcel.writeString(this.shareImage);
        parcel.writeInt(this.isDJEffect);
        parcel.writeString(this.publishTime);
        parcel.writeInt(this.isRecommend);
        parcel.writeInt(this.isNew);
        parcel.writeString(this.putooTopicMid);
        parcel.writeString(this.putooTopicName);
        parcel.writeString(this.effectPackageMd5);
        parcel.writeInt(this.effectPackageSize);
        parcel.writeString(this.songListEffectIcon);
        parcel.writeString(this.shortDescription);
    }

    public SSUGCEffectItem(int i10, String str, String str2, String[] strArr, String str3, String str4, String str5, String str6, String str7, String str8, int i11, String str9, int i12, int i13, String str10, String str11, String str12, int i14, String str13, String str14) {
        this.f10120id = i10;
        this.name = str;
        this.authorUin = str2;
        this.tags = strArr;
        this.detailDesc = str3;
        this.downloadLink = str4;
        this.listIcon = str5;
        this.detailIcon = str6;
        this.detailBackImage = str7;
        this.shareImage = str8;
        this.isDJEffect = i11;
        this.publishTime = str9;
        this.isRecommend = i12;
        this.isNew = i13;
        this.putooTopicMid = str10;
        this.putooTopicName = str11;
        this.effectPackageMd5 = str12;
        this.effectPackageSize = i14;
        this.songListEffectIcon = str13;
        this.shortDescription = str14;
    }

    private SSUGCEffectItem(Parcel parcel) {
        this.f10120id = parcel.readInt();
        this.name = parcel.readString();
        this.authorUin = parcel.readString();
        this.tags = parcel.createStringArray();
        this.detailDesc = parcel.readString();
        this.downloadLink = parcel.readString();
        this.listIcon = parcel.readString();
        this.detailIcon = parcel.readString();
        this.detailBackImage = parcel.readString();
        this.shareImage = parcel.readString();
        this.isDJEffect = parcel.readInt();
        this.publishTime = parcel.readString();
        this.isRecommend = parcel.readInt();
        this.isNew = parcel.readInt();
        this.putooTopicMid = parcel.readString();
        this.putooTopicName = parcel.readString();
        this.effectPackageMd5 = parcel.readString();
        this.effectPackageSize = parcel.readInt();
        this.songListEffectIcon = parcel.readString();
        this.shortDescription = parcel.readString();
    }
}
