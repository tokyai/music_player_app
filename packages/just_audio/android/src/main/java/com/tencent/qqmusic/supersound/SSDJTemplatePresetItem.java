package com.tencent.qqmusic.supersound;

import android.os.Bundle;
import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSDJTemplatePresetItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSDJTemplatePresetItem> CREATOR = new Parcelable.Creator<SSDJTemplatePresetItem>() {
        @Override
        public SSDJTemplatePresetItem createFromParcel(Parcel parcel) {
            return new SSDJTemplatePresetItem(parcel);
        }

        @Override
        public SSDJTemplatePresetItem[] newArray(int i10) {
            return new SSDJTemplatePresetItem[i10];
        }
    };

    public final int f10107id;

    public final int isCommon;

    public final int isDebug;

    public final String loadLink;

    public final String md5;

    public final String presetCNName;

    public final String presetENName;

    public final int size;

    public Bundle asBundle() {
        Bundle bundle = new Bundle();
        bundle.putSerializable("data", this);
        return bundle;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10107id);
        parcel.writeInt(this.isCommon);
        parcel.writeInt(this.isDebug);
        parcel.writeInt(this.size);
        parcel.writeString(this.presetENName);
        parcel.writeString(this.presetCNName);
        parcel.writeString(this.loadLink);
        parcel.writeString(this.md5);
    }

    public SSDJTemplatePresetItem(int i10, int i11, int i12, int i13, String str, String str2, String str3, String str4) {
        this.f10107id = i10;
        this.isCommon = i11;
        this.isDebug = i12;
        this.size = i13;
        this.presetENName = str;
        this.presetCNName = str2;
        this.loadLink = str3;
        this.md5 = str4;
    }

    private SSDJTemplatePresetItem(Parcel parcel) {
        this.f10107id = parcel.readInt();
        this.isCommon = parcel.readInt();
        this.isDebug = parcel.readInt();
        this.size = parcel.readInt();
        this.presetENName = parcel.readString();
        this.presetCNName = parcel.readString();
        this.loadLink = parcel.readString();
        this.md5 = parcel.readString();
    }
}
