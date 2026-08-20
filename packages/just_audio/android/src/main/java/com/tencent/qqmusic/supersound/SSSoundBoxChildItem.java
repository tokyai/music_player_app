package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSSoundBoxChildItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSSoundBoxChildItem> CREATOR = new Parcelable.Creator<SSSoundBoxChildItem>() {
        @Override
        public SSSoundBoxChildItem createFromParcel(Parcel parcel) {
            return new SSSoundBoxChildItem(parcel);
        }

        @Override
        public SSSoundBoxChildItem[] newArray(int i10) {
            return new SSSoundBoxChildItem[i10];
        }
    };

    public final int f10117id;
    public final String name;

    public SSSoundBoxChildItem(int i10, String str) {
        this.f10117id = i10;
        this.name = str;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10117id);
        parcel.writeString(this.name);
    }

    protected SSSoundBoxChildItem(Parcel parcel) {
        this.f10117id = parcel.readInt();
        this.name = parcel.readString();
    }
}
