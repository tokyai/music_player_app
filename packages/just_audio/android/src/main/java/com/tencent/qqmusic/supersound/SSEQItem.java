package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;
import java.io.Serializable;
import java.util.HashMap;

public class SSEQItem implements Parcelable, Serializable {
    public static final Parcelable.Creator<SSEQItem> CREATOR = new Parcelable.Creator<SSEQItem>() {
        @Override
        public SSEQItem createFromParcel(Parcel parcel) {
            return new SSEQItem(parcel);
        }

        @Override
        public SSEQItem[] newArray(int i10) {
            return new SSEQItem[i10];
        }
    };

    public final int f10110id;
    public final String name;
    public final HashMap<String, Float> params;
    public final int type;

    @Override
    public int describeContents() {
        return 0;
    }

    @Override
    public void writeToParcel(Parcel parcel, int i10) {
        parcel.writeInt(this.f10110id);
        parcel.writeInt(this.type);
        parcel.writeString(this.name);
        parcel.writeSerializable(this.params);
    }

    public SSEQItem(int i10, int i11, String str) {
        this.f10110id = i10;
        this.type = i11;
        this.name = str;
        this.params = new HashMap<>();
    }

    private SSEQItem(Parcel parcel) {
        this.f10110id = parcel.readInt();
        this.type = parcel.readInt();
        this.name = parcel.readString();
        this.params = (HashMap) parcel.readSerializable();
    }
}
