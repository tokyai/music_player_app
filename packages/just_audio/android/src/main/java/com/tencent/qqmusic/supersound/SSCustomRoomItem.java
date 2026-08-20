package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSCustomRoomItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCustomRoomItem> CREATOR = new Parcelable.Creator<SSCustomRoomItem>() {
        @Override
        public SSCustomRoomItem createFromParcel(Parcel parcel) {
            return new SSCustomRoomItem(parcel);
        }

        @Override
        public SSCustomRoomItem[] newArray(int i10) {
            return new SSCustomRoomItem[i10];
        }
    };
    public static int INVALID_ID = -1;
    public boolean bTemp;

    public int f10106id;
    public String name;
    public int[] seatStatus;
    public String time;

    public SSCustomRoomItem(int i10, String str, String str2, boolean z10, int[] iArr) {
        this.f10106id = i10;
        this.name = str;
        this.time = str2;
        this.bTemp = z10;
        this.seatStatus = iArr;
    }

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10106id);
        parcel.writeString(this.name);
        parcel.writeString(this.time);
        parcel.writeIntArray(this.seatStatus);
        parcel.writeByte(this.bTemp ? (byte) 1 : (byte) 0);
    }

    public SSCustomRoomItem() {
        this.f10106id = INVALID_ID;
        this.name = "";
        this.time = "";
        this.bTemp = false;
    }

    protected SSCustomRoomItem(Parcel parcel) {
        this.f10106id = parcel.readInt();
        this.name = parcel.readString();
        this.time = parcel.readString();
        this.seatStatus = parcel.createIntArray();
        this.bTemp = parcel.readByte() != 0;
    }
}
