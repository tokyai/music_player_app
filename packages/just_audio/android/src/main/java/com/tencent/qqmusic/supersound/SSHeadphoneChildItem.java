package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSHeadphoneChildItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSHeadphoneChildItem> CREATOR = new Parcelable.Creator<SSHeadphoneChildItem>() {
        @Override
        public SSHeadphoneChildItem createFromParcel(Parcel parcel) {
            return new SSHeadphoneChildItem(parcel);
        }

        @Override
        public SSHeadphoneChildItem[] newArray(int i10) {
            return new SSHeadphoneChildItem[i10];
        }
    };

    public final int f10112id;
    public final String name;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10112id);
        parcel.writeString(this.name);
    }

    public SSHeadphoneChildItem(int i10, String str) {
        this.f10112id = i10;
        this.name = str;
    }

    private SSHeadphoneChildItem(Parcel parcel) {
        this.f10112id = parcel.readInt();
        this.name = parcel.readString();
    }
}
