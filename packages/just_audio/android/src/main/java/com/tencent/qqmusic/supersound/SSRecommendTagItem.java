package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;

public class SSRecommendTagItem implements Parcelable {
    public static final Parcelable.Creator<SSRecommendTagItem> CREATOR = new Parcelable.Creator<SSRecommendTagItem>() {
        @Override
        public SSRecommendTagItem createFromParcel(Parcel parcel) {
            return new SSRecommendTagItem(parcel);
        }

        @Override
        public SSRecommendTagItem[] newArray(int i10) {
            return new SSRecommendTagItem[i10];
        }
    };

    public final int f10115id;
    public final String name;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.name);
        parcel.writeInt(this.f10115id);
    }

    public SSRecommendTagItem(int i10, String str) {
        this.f10115id = i10;
        this.name = str;
    }

    private SSRecommendTagItem(Parcel parcel) {
        this.name = parcel.readString();
        this.f10115id = parcel.readInt();
    }
}
