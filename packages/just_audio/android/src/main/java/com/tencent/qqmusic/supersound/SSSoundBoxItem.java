package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSSoundBoxItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSSoundBoxItem> CREATOR = new Parcelable.Creator<SSSoundBoxItem>() {
        @Override
        public SSSoundBoxItem createFromParcel(Parcel parcel) {
            return new SSSoundBoxItem(parcel);
        }

        @Override
        public SSSoundBoxItem[] newArray(int i10) {
            return new SSSoundBoxItem[i10];
        }
    };
    public final String icon;

    public final int f10118id;
    public final String name;
    public final String nameEnglish;
    public final int type;

    public SSSoundBoxItem(int i10, int i11, String str, String str2, String str3) {
        this.f10118id = i10;
        this.type = i11;
        this.name = str;
        this.nameEnglish = str2;
        this.icon = str3;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.name);
        parcel.writeInt(this.f10118id);
        parcel.writeInt(this.type);
        parcel.writeString(this.nameEnglish);
        parcel.writeString(this.icon);
    }

    protected SSSoundBoxItem(Parcel parcel) {
        this.name = parcel.readString();
        this.f10118id = parcel.readInt();
        this.type = parcel.readInt();
        this.nameEnglish = parcel.readString();
        this.icon = parcel.readString();
    }
}
