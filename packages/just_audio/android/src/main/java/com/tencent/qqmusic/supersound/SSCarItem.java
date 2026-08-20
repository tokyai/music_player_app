package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSCarItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCarItem> CREATOR = new Parcelable.Creator<SSCarItem>() {
        @Override
        public SSCarItem createFromParcel(Parcel parcel) {
            return new SSCarItem(parcel);
        }

        @Override
        public SSCarItem[] newArray(int i10) {
            return new SSCarItem[i10];
        }
    };
    public final String icon;

    public final int f10102id;
    public final String name;
    public final int type;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10102id);
        parcel.writeInt(this.type);
        parcel.writeString(this.name);
        parcel.writeString(this.icon);
    }

    public SSCarItem(int i10, int i11, String str, String str2) {
        this.f10102id = i10;
        this.type = i11;
        this.name = str;
        this.icon = str2;
    }

    private SSCarItem(Parcel parcel) {
        this.f10102id = parcel.readInt();
        this.type = parcel.readInt();
        this.name = parcel.readString();
        this.icon = parcel.readString();
    }
}
