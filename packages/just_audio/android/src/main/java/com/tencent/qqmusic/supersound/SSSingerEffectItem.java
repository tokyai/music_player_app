package com.tencent.qqmusic.supersound;

import android.os.Parcel;
import android.os.Parcelable;

public class SSSingerEffectItem extends SSRecommendItem {
    public static final Parcelable.Creator<SSSingerEffectItem> CREATOR = new Parcelable.Creator<SSSingerEffectItem>() {
        @Override
        public SSSingerEffectItem createFromParcel(Parcel parcel) {
            return new SSSingerEffectItem(parcel);
        }

        @Override
        public SSSingerEffectItem[] newArray(int i10) {
            return new SSSingerEffectItem[i10];
        }
    };

    public String getUniqueId() {
        return String.valueOf(this.type) + this.f10114id;
    }

    public SSSingerEffectItem(int i10, int i11, String str, String[] strArr, String str2, String str3, String str4, String str5, String str6, long[] jArr, String str7, String str8, String str9, String[] strArr2, String str10, String str11, String str12, int i12, String str13, int i13, boolean z10, boolean z11, String str14, String str15) {
        super(i10, i11, str, strArr, str2, str3, str4, str5, str6, jArr, str7, str8, str9, strArr2, str10, str11, str12, i12, str13, i13, z10, z11, str14, str15);
    }

    private SSSingerEffectItem(Parcel parcel) {
        super(parcel);
    }
}
