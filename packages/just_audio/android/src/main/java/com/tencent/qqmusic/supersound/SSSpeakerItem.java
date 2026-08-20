package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSSpeakerItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSSpeakerItem> CREATOR = new Parcelable.Creator<SSSpeakerItem>() {
        @Override
        public SSSpeakerItem createFromParcel(Parcel parcel) {
            return new SSSpeakerItem(parcel);
        }

        @Override
        public SSSpeakerItem[] newArray(int i10) {
            return new SSSpeakerItem[i10];
        }
    };
    public final String icon;

    public final int f10119id;
    public final String name;
    public final String nameEnglish;
    public final int type;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10119id);
        parcel.writeInt(this.type);
        parcel.writeString(this.name);
        parcel.writeString(this.nameEnglish);
        parcel.writeString(this.icon);
    }

    public SSSpeakerItem(int i10, int i11, String str, String str2, String str3) {
        this.f10119id = i10;
        this.type = i11;
        this.name = str;
        this.nameEnglish = str2;
        this.icon = str3;
    }

    private SSSpeakerItem(Parcel parcel) {
        this.f10119id = parcel.readInt();
        this.type = parcel.readInt();
        this.name = parcel.readString();
        this.nameEnglish = parcel.readString();
        this.icon = parcel.readString();
    }
}
