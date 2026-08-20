package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSPromoteItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSPromoteItem> CREATOR = new Parcelable.Creator<SSPromoteItem>() {
        @Override
        public SSPromoteItem createFromParcel(Parcel parcel) {
            return new SSPromoteItem(parcel);
        }

        @Override
        public SSPromoteItem[] newArray(int i10) {
            return new SSPromoteItem[i10];
        }
    };
    public final String jumpLink;
    public final String promoteImage;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeString(this.promoteImage);
        parcel.writeString(this.jumpLink);
    }

    public SSPromoteItem(String str, String str2) {
        this.promoteImage = str;
        this.jumpLink = str2;
    }

    private SSPromoteItem(Parcel parcel) {
        this.promoteImage = parcel.readString();
        this.jumpLink = parcel.readString();
    }
}
