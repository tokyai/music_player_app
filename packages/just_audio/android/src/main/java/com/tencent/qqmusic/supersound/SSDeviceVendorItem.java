package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSDeviceVendorItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSDeviceVendorItem> CREATOR = new Parcelable.Creator<SSDeviceVendorItem>() {
        @Override
        public SSDeviceVendorItem createFromParcel(Parcel parcel) {
            return new SSDeviceVendorItem(parcel);
        }

        @Override
        public SSDeviceVendorItem[] newArray(int i10) {
            return new SSDeviceVendorItem[i10];
        }
    };
    public final String icon;

    public final int f10109id;
    public final String name;
    public final String nameEnglish;
    public final int type;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.name);
        parcel.writeInt(this.f10109id);
        parcel.writeInt(this.type);
        parcel.writeString(this.nameEnglish);
        parcel.writeString(this.icon);
    }

    public SSDeviceVendorItem(int i10, int i11, String str, String str2, String str3) {
        this.f10109id = i10;
        this.type = i11;
        this.name = str;
        this.nameEnglish = str2;
        this.icon = str3;
    }

    private SSDeviceVendorItem(Parcel parcel) {
        this.name = parcel.readString();
        this.f10109id = parcel.readInt();
        this.type = parcel.readInt();
        this.nameEnglish = parcel.readString();
        this.icon = parcel.readString();
    }
}
