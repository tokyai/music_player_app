package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSCustomAddRtItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCustomAddRtItem> CREATOR = new Parcelable.Creator<SSCustomAddRtItem>() {
        @Override
        public SSCustomAddRtItem createFromParcel(Parcel parcel) {
            return new SSCustomAddRtItem(parcel);
        }

        @Override
        public SSCustomAddRtItem[] newArray(int i10) {
            return new SSCustomAddRtItem[i10];
        }
    };
    public final int addID;
    public final int rtErr;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.rtErr);
        parcel.writeInt(this.addID);
    }

    public SSCustomAddRtItem(int i10, int i11) {
        this.rtErr = i10;
        this.addID = i11;
    }

    private SSCustomAddRtItem(Parcel parcel) {
        this.rtErr = parcel.readInt();
        this.addID = parcel.readInt();
    }
}
