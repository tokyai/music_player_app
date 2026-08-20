package com.ryanheise.just_audio.supersound;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.util.Log;

import com.tencent.qqmusic.supersound.SSRecommendItem;
import com.tencent.qqmusic.supersound.SuperSoundConfigure;
import com.tencent.qqmusic.supersound.SuperSoundJni;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** Process-wide lifecycle and selection state for the bundled SuperSound DSP. */
public final class SuperSoundController {
    private static final String TAG = "SuperSoundController";
    private static final String ASSET_NAME = "KwSuperSoundV3.zip";
    private static final String RESOURCE_DIR = "KwSuperSoundV3";
    private static final int SDK_INIT_VERSION = 17;
    private static final int EFFECT_TYPE_RECOMMEND = 1;

    private static final Object INIT_LOCK = new Object();
    private static final ExecutorService INIT_EXECUTOR =
            Executors.newSingleThreadExecutor(runnable -> {
                Thread thread = new Thread(runnable, "supersound-init");
                thread.setDaemon(true);
                return thread;
            });
    private static final List<InitializationCallback> INIT_CALLBACKS = new ArrayList<>();
    private static final AtomicInteger DESIRED_TYPE = new AtomicInteger(EFFECT_TYPE_RECOMMEND);
    private static final AtomicInteger DESIRED_ID = new AtomicInteger(0);
    private static final AtomicLong EFFECT_REVISION = new AtomicLong(0);

    private static volatile boolean initializationStarted;
    private static volatile boolean ready;
    private static volatile Map<String, Object> initializationResult;

    private SuperSoundController() {}

    public interface InitializationCallback {
        void onComplete(Map<String, Object> result);
    }

    public static final class EffectSelection {
        public final int type;
        public final int id;
        public final long revision;

        private EffectSelection(int type, int id, long revision) {
            this.type = type;
            this.id = id;
            this.revision = revision;
        }
    }

    public static void initialize(Context context, InitializationCallback callback) {
        Map<String, Object> completedResult;
        synchronized (INIT_LOCK) {
            completedResult = initializationResult;
            if (completedResult == null) {
                if (callback != null) {
                    INIT_CALLBACKS.add(callback);
                }
                if (!initializationStarted) {
                    initializationStarted = true;
                    Context appContext = context.getApplicationContext();
                    INIT_EXECUTOR.execute(() -> finishInitialization(runInitialization(appContext)));
                }
                return;
            }
        }
        if (callback != null) {
            callback.onComplete(completedResult);
        }
    }

    public static void setDesiredEffect(int type, int id) {
        DESIRED_TYPE.set(type > 0 ? type : EFFECT_TYPE_RECOMMEND);
        DESIRED_ID.set(Math.max(0, id));
        EFFECT_REVISION.incrementAndGet();
    }

    static EffectSelection getDesiredEffect() {
        while (true) {
            long before = EFFECT_REVISION.get();
            int type = DESIRED_TYPE.get();
            int id = DESIRED_ID.get();
            long after = EFFECT_REVISION.get();
            if (before == after) {
                return new EffectSelection(type, id, after);
            }
        }
    }

    static boolean isReady() {
        return ready;
    }

    static long createInstance(int sampleRate, int channelCount) {
        if (!ready || sampleRate <= 0 || sampleRate > 48000
                || (channelCount != 1 && channelCount != 2)) {
            return 0;
        }
        try {
            return SuperSoundJni.supersound_create_inst(sampleRate, channelCount);
        } catch (Throwable error) {
            Log.e(TAG, "Unable to create DSP instance", error);
            return 0;
        }
    }

    static boolean applyEffect(long instance, int type, int id) {
        if (instance == 0 || id <= 0) {
            return false;
        }
        try {
            int setResult = SuperSoundJni.supersound_set_effect(instance, type, id);
            int commitResult = SuperSoundJni.supersound_effect_modify_complete(instance);
            return setResult == SuperSoundJni.ERR_SUPERSOUND_SUCCESS
                    && commitResult == SuperSoundJni.ERR_SUPERSOUND_SUCCESS;
        } catch (Throwable error) {
            Log.e(TAG, "Unable to apply DSP effect", error);
            return false;
        }
    }

    static void destroyInstance(long instance) {
        if (instance == 0) {
            return;
        }
        try {
            SuperSoundJni.supersound_destory_inst(instance);
        } catch (Throwable error) {
            Log.w(TAG, "Unable to destroy DSP instance", error);
        }
    }

    private static Map<String, Object> runInitialization(Context context) {
        if (!isSupportedAbi()) {
            return result(false, "unsupported", "当前 CPU 架构不支持 DSP", new ArrayList<>());
        }
        try {
            File root = installResources(context);
            configurePreferences(context);
            SuperSoundJni.supersound_register_func();
            String rootPath = root.getAbsolutePath() + File.separator;
            if (!SuperSoundJni.supersound_init_path(rootPath, rootPath)) {
                return result(false, "error", "DSP 预设路径初始化失败", new ArrayList<>());
            }
            int initCode = SuperSoundJni.supersound_init(SDK_INIT_VERSION);
            if (initCode != SuperSoundJni.ERR_SUPERSOUND_SUCCESS) {
                return result(false, "error", "DSP 初始化失败（" + initCode + "）", new ArrayList<>());
            }
            List<Map<String, Object>> presets = readBundledPresets(root);
            if (presets.isEmpty()) {
                return result(false, "error", "DSP 预设读取失败", presets);
            }
            ready = true;
            return result(true, "ready", "", presets);
        } catch (Throwable error) {
            Log.e(TAG, "DSP initialization failed; audio will remain in bypass mode", error);
            return result(false, "error",
                    error.getMessage() == null ? "DSP 初始化失败" : error.getMessage(),
                    new ArrayList<>());
        }
    }

    private static void finishInitialization(Map<String, Object> result) {
        List<InitializationCallback> callbacks;
        synchronized (INIT_LOCK) {
            initializationResult = result;
            callbacks = new ArrayList<>(INIT_CALLBACKS);
            INIT_CALLBACKS.clear();
        }
        for (InitializationCallback callback : callbacks) {
            callback.onComplete(result);
        }
    }

    private static boolean isSupportedAbi() {
        String abi = Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP
                ? Build.SUPPORTED_ABIS[0]
                : Build.CPU_ABI;
        return "arm64-v8a".equals(abi) || "armeabi-v7a".equals(abi) || "x86".equals(abi);
    }

    private static File installResources(Context context) throws IOException {
        File parent = new File(context.getFilesDir(), "supersound");
        File installDir = new File(parent, "v3");
        File resourceRoot = new File(installDir, RESOURCE_DIR);
        if (isValidResourceRoot(resourceRoot)) {
            return resourceRoot;
        }

        File stagingDir = new File(parent, "v3-installing");
        deleteRecursively(stagingDir);
        if (!stagingDir.mkdirs() && !stagingDir.isDirectory()) {
            throw new IOException("无法创建 DSP 资源目录");
        }
        try (InputStream assetStream = context.getAssets().open(ASSET_NAME)) {
            unzip(assetStream, stagingDir);
        }
        File stagedRoot = new File(stagingDir, RESOURCE_DIR);
        if (!isValidResourceRoot(stagedRoot)) {
            deleteRecursively(stagingDir);
            throw new IOException("DSP 预设资源不完整");
        }
        deleteRecursively(installDir);
        if (!stagingDir.renameTo(installDir)) {
            deleteRecursively(stagingDir);
            throw new IOException("DSP 预设资源安装失败");
        }
        return new File(installDir, RESOURCE_DIR);
    }

    private static boolean isValidResourceRoot(File root) {
        return new File(root, "recommendbase/recommendbase.json").isFile()
                && new File(root, "recommenddisplay/recommenddisplay.json").isFile();
    }

    private static void unzip(InputStream input, File destination) throws IOException {
        String destinationPath = destination.getCanonicalPath() + File.separator;
        try (ZipInputStream zip = new ZipInputStream(new BufferedInputStream(input))) {
            ZipEntry entry;
            byte[] buffer = new byte[16 * 1024];
            while ((entry = zip.getNextEntry()) != null) {
                File output = new File(destination, entry.getName());
                String outputPath = output.getCanonicalPath();
                if (!outputPath.startsWith(destinationPath)) {
                    throw new IOException("DSP 压缩包包含非法路径");
                }
                if (entry.isDirectory()) {
                    if (!output.mkdirs() && !output.isDirectory()) {
                        throw new IOException("无法创建 DSP 资源目录");
                    }
                } else {
                    File parent = output.getParentFile();
                    if (parent != null && !parent.mkdirs() && !parent.isDirectory()) {
                        throw new IOException("无法创建 DSP 资源目录");
                    }
                    try (BufferedOutputStream out =
                                 new BufferedOutputStream(new FileOutputStream(output))) {
                        int count;
                        while ((count = zip.read(buffer)) != -1) {
                            out.write(buffer, 0, count);
                        }
                    }
                }
                zip.closeEntry();
            }
        }
    }

    private static void configurePreferences(Context context) {
        SharedPreferences preferences =
                context.getSharedPreferences("supersound", Context.MODE_PRIVATE);
        SuperSoundConfigure.setSPListener(new SuperSoundConfigure.SPListener() {
            @Override
            public void deleteSP(String key) {
                preferences.edit().remove(key).apply();
            }

            @Override
            public String getSP(String key) {
                return preferences.getString(key, "");
            }

            @Override
            public void setSP(String key, String value) {
                SharedPreferences.Editor editor = preferences.edit();
                if (value == null) {
                    editor.remove(key);
                } else {
                    editor.putString(key, value);
                }
                editor.apply();
            }
        });
    }

    private static List<Map<String, Object>> readBundledPresets(File root) {
        Set<Integer> bundledIds = new HashSet<>();
        File[] files = new File(root, "recommendbase").listFiles();
        if (files != null) {
            for (File file : files) {
                String name = file.getName();
                int separator = name.indexOf('-');
                if (separator <= 0 || !name.endsWith(".aep")) {
                    continue;
                }
                try {
                    bundledIds.add(Integer.parseInt(name.substring(0, separator)));
                } catch (NumberFormatException ignored) {
                    // Ignore non-preset support files.
                }
            }
        }

        SSRecommendItem[] nativeItems = SuperSoundJni.supersound_get_recommend_item_list();
        List<Map<String, Object>> presets = new ArrayList<>();
        if (nativeItems == null) {
            return presets;
        }
        for (SSRecommendItem item : nativeItems) {
            if (item == null || item.f10114id <= 0 || !bundledIds.contains(item.f10114id)) {
                continue;
            }
            Map<String, Object> preset = new HashMap<>();
            preset.put("id", item.f10114id);
            preset.put("type", item.type > 0 ? item.type : EFFECT_TYPE_RECOMMEND);
            preset.put("name", valueOrEmpty(item.name));
            preset.put("description", firstNonEmpty(item.shortDescription, item.description));
            preset.put("tags", item.tags == null
                    ? new ArrayList<String>()
                    : Arrays.asList(item.tags));
            presets.add(preset);
        }
        return presets;
    }

    private static String firstNonEmpty(String first, String second) {
        return first != null && !first.trim().isEmpty() ? first : valueOrEmpty(second);
    }

    private static String valueOrEmpty(String value) {
        return value == null ? "" : value;
    }

    private static Map<String, Object> result(
            boolean available,
            String state,
            String message,
            List<Map<String, Object>> presets) {
        Map<String, Object> result = new HashMap<>();
        result.put("available", available);
        result.put("state", state);
        result.put("message", message);
        result.put("presets", presets);
        return result;
    }

    private static void deleteRecursively(File file) throws IOException {
        if (!file.exists()) {
            return;
        }
        File[] children = file.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        if (!file.delete() && file.exists()) {
            throw new IOException("无法清理旧 DSP 资源");
        }
    }
}
