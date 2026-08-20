package com.tencent.qqmusic.supersound;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

class ZipUtils {
    private static final String TAG = "ZipUtils";

    ZipUtils() {
    }

    static void unzip(String str, String str2) {
        try {
            File file = new File(str2);
            if (!file.isDirectory()) {
                file.mkdirs();
            }
            ZipInputStream zipInputStream = new ZipInputStream(new FileInputStream(str));
            while (true) {
                try {
                    ZipEntry nextEntry = zipInputStream.getNextEntry();
                    if (nextEntry == null) {
                        zipInputStream.close();
                        return;
                    }
                    String str3 = str2 + File.separator + nextEntry.getName();
                    if (nextEntry.isDirectory()) {
                        File file2 = new File(str3);
                        if (!file2.isDirectory()) {
                            file2.mkdirs();
                        }
                    } else {
                        File parentFile = new File(str3).getParentFile();
                        if (parentFile != null && !parentFile.exists()) {
                            parentFile.mkdirs();
                        }
                        FileOutputStream fileOutputStream = new FileOutputStream(str3, false);
                        while (true) {
                            try {
                                int i10 = zipInputStream.read();
                                if (i10 == -1) {
                                    break;
                                } else {
                                    fileOutputStream.write(i10);
                                }
                            } catch (Throwable th) {
                                fileOutputStream.close();
                                throw th;
                            }
                        }
                        zipInputStream.closeEntry();
                        fileOutputStream.close();
                    }
                } catch (Throwable th2) {
                    zipInputStream.close();
                    throw th2;
                }
            }
        } catch (Exception e10) {
            SuperSoundConfigure.getLogProxy().e(TAG, "Unzip exception", e10);
        }
    }
}
