package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;

public class SSCreateCustomRoomItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSCreateCustomRoomItem> CREATOR = new Parcelable.Creator<SSCreateCustomRoomItem>() {
        @Override
        public SSCreateCustomRoomItem createFromParcel(Parcel parcel) {
            return new SSCreateCustomRoomItem(parcel);
        }

        @Override
        public SSCreateCustomRoomItem[] newArray(int i10) {
            return new SSCreateCustomRoomItem[i10];
        }
    };
    public static int INVALID_ID = -1;
    public int FIRId;
    public boolean bTemp;

    public int f10104id;
    public float leftAngle;
    public String name;
    public float rightAngle;
    public int seatCount;
    public int seatPosition;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10104id);
        parcel.writeString(this.name);
        parcel.writeInt(this.seatCount);
        parcel.writeInt(this.seatPosition);
        parcel.writeInt(this.FIRId);
        parcel.writeFloat(this.leftAngle);
        parcel.writeFloat(this.rightAngle);
        parcel.writeInt(this.bTemp ? 1 : 0);
    }

    public SSCreateCustomRoomItem(int i10, String str, int i11, int i12, int i13, float f10, float f11, boolean z10) {
        this.f10104id = i10;
        this.name = str;
        this.seatCount = i11;
        this.seatPosition = i12;
        this.FIRId = i13;
        this.leftAngle = f10;
        this.rightAngle = f11;
        this.bTemp = z10;
    }

    public SSCreateCustomRoomItem() {
        this.f10104id = INVALID_ID;
        this.name = "";
        this.seatCount = 4;
        this.seatPosition = 0;
        this.FIRId = 0;
        this.leftAngle = 0.0f;
        this.rightAngle = 0.0f;
        this.bTemp = false;
    }

    private SSCreateCustomRoomItem(Parcel parcel) {
        this.f10104id = parcel.readInt();
        this.name = parcel.readString();
        this.seatCount = parcel.readInt();
        this.seatPosition = parcel.readInt();
        this.FIRId = parcel.readInt();
        this.leftAngle = parcel.readFloat();
        this.rightAngle = parcel.readFloat();
        this.bTemp = parcel.readInt() != 0;
    }
}
