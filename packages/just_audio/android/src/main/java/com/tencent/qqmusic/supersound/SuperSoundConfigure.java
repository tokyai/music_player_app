package com.tencent.qqmusic.supersound;

import android.util.Log;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

public class SuperSoundConfigure {
    private static AsyncCallBack asyncCallBack;
    private static CommonNotify sCommonNotify;
    private static SuperSoundLog sLogProxy;
    private static SPListener sSPListener;
    private static final SuperSoundLog DEFAULT_LOG_PROXY = new SuperSoundLog() {
        @Override
        public void d(String str, String str2) {
            Log.d(str, str2);
        }

        @Override
        public void e(String str, String str2, Throwable th) {
            Log.e(str, str2, th);
        }

        @Override
        public void i(String str, String str2) {
            Log.i(str, str2);
        }

        @Override
        public void e(String str, String str2) {
            Log.e(str, str2);
        }
    };
    private static SoLoader sSoLoader = null;
    private static final SoLoader DEFAULT_SO_LOADER = new SoLoader() {
        @Override
        public boolean loadLibrary(String str) {
            try {
                System.loadLibrary(str);
                return true;
            } catch (Throwable unused) {
                return false;
            }
        }
    };
    private static Downloader sDownloader = null;
    private static final Downloader DUMMY_DOWNLOADER = new Downloader() {
        @Override
        public void download(String str, String str2, DownloaderCallback downloaderCallback) {
            downloaderCallback.onDownloadFinished(-1, -1);
        }
    };

    @Nullable
    private static SetEffectCallback sSetEffectCallback = null;
    private static HTTPRequest sHttpRequest = null;
    private static final HTTPRequest DUMMY_HTTP_REQUEST = new HTTPRequest() {
        @Override
        public void request(int i10, String str, String str2, HTTPRequestCallback hTTPRequestCallback) {
            hTTPRequestCallback.onRequestFinished(-1, -1, null);
        }
    };
    private static UniteHttpRequest sUniteHttpRequest = null;
    private static final UniteHttpRequest DUMMY_UNITE_HTTP_REQUEST = new UniteHttpRequest() {
        @Override
        public void requestUnite(String str, String str2, String str3, UniteHTTPRequestCallback uniteHTTPRequestCallback) {
            uniteHTTPRequestCallback.onUniteRequestFinished(-1, "");
        }
    };

    public interface AsyncCallBack {
        void onAsyncCallBack(int i10, String str);
    }

    public interface CommonNotify {
        void OnCommonEffectUpdate(int i10);

        void OnCustomCarEffectUpdate();

        void OnCustomEffectUpdate();
    }

    public interface Downloader {
        void download(String str, String str2, DownloaderCallback downloaderCallback);
    }

    public interface DownloaderCallback {
        void onDownloadFinished(int i10, int i11);
    }

    public interface HTTPRequest {
        void request(int i10, String str, String str2, HTTPRequestCallback hTTPRequestCallback);
    }

    public interface HTTPRequestCallback {
        void onRequestFinished(int i10, int i11, String str);
    }

    public interface SPListener {
        void deleteSP(String str);

        String getSP(String str);

        void setSP(String str, String str2);
    }

    public interface SetEffectCallback {
        void onSetEffectCallback(int i10, int i11, int i12);
    }

    public interface SoLoader {
        boolean loadLibrary(String str);
    }

    public interface SuperSoundLog {
        void d(String str, String str2);

        void e(String str, String str2);

        void e(String str, String str2, Throwable th);

        void i(String str, String str2);
    }

    public interface UniteHTTPRequestCallback {
        void onUniteRequestFinished(int i10, String str);
    }

    public interface UniteHttpRequest {
        void requestUnite(String str, String str2, String str3, UniteHTTPRequestCallback uniteHTTPRequestCallback);
    }

    @Nullable
    public static AsyncCallBack getAsyncCallBack() {
        return asyncCallBack;
    }

    @Nullable
    public static CommonNotify getCommonNotify() {
        return sCommonNotify;
    }

    @NonNull
    public static Downloader getDownloader() {
        Downloader downloader = sDownloader;
        return downloader == null ? DUMMY_DOWNLOADER : downloader;
    }

    @NonNull
    public static HTTPRequest getHttpRequest() {
        HTTPRequest hTTPRequest = sHttpRequest;
        return hTTPRequest == null ? DUMMY_HTTP_REQUEST : hTTPRequest;
    }

    @NonNull
    public static SuperSoundLog getLogProxy() {
        SuperSoundLog superSoundLog = sLogProxy;
        return superSoundLog == null ? DEFAULT_LOG_PROXY : superSoundLog;
    }

    @Nullable
    public static SPListener getSPListener() {
        return sSPListener;
    }

    @Nullable
    static SetEffectCallback getSetEffectCallback() {
        return sSetEffectCallback;
    }

    @NonNull
    public static SoLoader getSoLoader() {
        SoLoader soLoader = sSoLoader;
        return soLoader == null ? DEFAULT_SO_LOADER : soLoader;
    }

    @NonNull
    public static UniteHttpRequest getUniteHttpRequest() {
        UniteHttpRequest uniteHttpRequest = sUniteHttpRequest;
        return uniteHttpRequest == null ? DUMMY_UNITE_HTTP_REQUEST : uniteHttpRequest;
    }

    public static boolean hasSetLogProxy() {
        return sLogProxy != null;
    }

    public static void setAsyncCallBack(AsyncCallBack asyncCallBack2) {
        asyncCallBack = asyncCallBack2;
    }

    public static void setCommonNotify(CommonNotify commonNotify) {
        sCommonNotify = commonNotify;
    }

    public static void setDownloader(Downloader downloader) {
        sDownloader = downloader;
    }

    public static void setEffectCallback(@Nullable SetEffectCallback setEffectCallback) {
        sSetEffectCallback = setEffectCallback;
    }

    public static void setHTTPRequest(HTTPRequest hTTPRequest) {
        sHttpRequest = hTTPRequest;
    }

    public static void setSPListener(SPListener sPListener) {
        sSPListener = sPListener;
    }

    public static void setSuperSoundLog(SuperSoundLog superSoundLog) {
        sLogProxy = superSoundLog;
    }

    public static void setUniteHTTPRequest(UniteHttpRequest uniteHttpRequest) {
        sUniteHttpRequest = uniteHttpRequest;
    }
}
