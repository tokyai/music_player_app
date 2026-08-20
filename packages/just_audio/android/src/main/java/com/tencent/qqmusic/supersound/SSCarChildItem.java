package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSCarChildItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCarChildItem> CREATOR = new Parcelable.Creator<SSCarChildItem>() {
        @Override
        public SSCarChildItem createFromParcel(Parcel parcel) {
            return new SSCarChildItem(parcel);
        }

        @Override
        public SSCarChildItem[] newArray(int i10) {
            return new SSCarChildItem[i10];
        }
    };

    public final int f10101id;
    public final String name;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10101id);
        parcel.writeString(this.name);
    }

    public SSCarChildItem(int i10, String str) {
        this.f10101id = i10;
        this.name = str;
    }

    private SSCarChildItem(Parcel parcel) {
        this.f10101id = parcel.readInt();
        this.name = parcel.readString();
    }
}
