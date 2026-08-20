package com.tencent.qqmusic.supersound;

import com.tencent.qqmusic.supersound.SuperSoundConfigure;
import java.io.File;
import java.util.Locale;

public class SuperSoundJni {
    public static final int ERR_SUPERSOUND_MEMORY = 2001;
    public static final int ERR_SUPERSOUND_PARAM = 2000;
    public static final int ERR_SUPERSOUND_PARAMETER = 2002;
    public static final int ERR_SUPERSOUND_SUCCESS = 0;
    public static final int LOG_LEVEL_CRITICAL = 8;
    public static final int LOG_LEVEL_DEBUG = 1;
    public static final int LOG_LEVEL_ERROR = 4;
    public static final int LOG_LEVEL_INFO = 2;
    public static final int LOG_LEVEL_VERBOSE = 2;
    private static final String TAG = "SuperSoundJni";
    public static final int WRN_SUPERSOUND_GENERIC = 10000;
    public static final int WRN_SUPERSOUND_IO_CHANGED = 11000;
    public static final int WRN_SUPERSOUND_UNCHANGED = 12000;

    static {
        try {
            SuperSoundConfigure.getSoLoader().loadLibrary("SuperSound3");
            SuperSoundConfigure.getLogProxy().i(TAG, String.format(Locale.ENGLISH, "[static initializer] done. sdk version: %d, preset version: %d", Integer.valueOf(supersound_get_vesion()), Integer.valueOf(supersound_get_flatbuffer_version())));
        } catch (Throwable th) {
            SuperSoundConfigure.getLogProxy().e(TAG, "[static initializer] failed to load SuperSound2 lib!", th);
        }
    }

    public static void OnCommonEffectUpdate(int i10) {
        SuperSoundConfigure.CommonNotify commonNotify = SuperSoundConfigure.getCommonNotify();
        if (commonNotify != null) {
            commonNotify.OnCommonEffectUpdate(i10);
        }
    }

    public static void OnCustomCarEffectUpdate() {
        SuperSoundConfigure.CommonNotify commonNotify = SuperSoundConfigure.getCommonNotify();
        if (commonNotify != null) {
            commonNotify.OnCustomCarEffectUpdate();
        }
    }

    public static void OnCustomEffectUpdate() {
        SuperSoundConfigure.CommonNotify commonNotify = SuperSoundConfigure.getCommonNotify();
        if (commonNotify != null) {
            commonNotify.OnCustomEffectUpdate();
        }
    }

    public static native byte[] ae_dispatcher(long j10, int i10, int i11, int i12, byte[] bArr, float f10);

    public static native long audio_feature_analyzer_create_inst(int i10, int i11);

    public static native int audio_feature_analyzer_destroy_inst(long j10);

    public static native int audio_feature_analyzer_get_buf_time(long j10, int[] iArr, int[] iArr2);

    public static native SSAudioFeature audio_feature_analyzer_get_feature(long j10, long j11, int i10);

    public static native int audio_feature_analyzer_push(long j10, byte[] bArr, int i10);

    public static native int audio_feature_analyzer_pushf(long j10, float[] fArr, int i10);

    public static native int audio_feature_analyzer_seek(long j10, long j11);

    public static native int audio_feature_analyzer_set_buf_data(long j10, boolean z10);

    public static void deleteSP(String str) {
        SuperSoundConfigure.SPListener sPListener = SuperSoundConfigure.getSPListener();
        if (sPListener != null) {
            sPListener.deleteSP(str);
        }
    }

    public static void download(final String str, final String str2, final long j10, final long j11) {
        SuperSoundConfigure.getLogProxy().i(TAG, "httpRequest " + str + " path:" + str2 + " userData:" + j10);
        SuperSoundConfigure.getDownloader().download(str, str2, new SuperSoundConfigure.DownloaderCallback() {
            @Override
            public void onDownloadFinished(int i10, int i11) {
                SuperSoundJni.supersound_on_download_finished(j11, j10, 0, 0, str, str2);
            }
        });
    }

    public static String getSP(String str) {
        SuperSoundConfigure.SPListener sPListener = SuperSoundConfigure.getSPListener();
        return sPListener != null ? sPListener.getSP(str) : "";
    }

    public static void httpRequest(int i10, String str, String str2, final long j10, final long j11) {
        SuperSoundConfigure.getLogProxy().i(TAG, "httpRequest " + str + " content:" + str2 + " userData:" + j10);
        SuperSoundConfigure.getHttpRequest().request(i10, str, str2, new SuperSoundConfigure.HTTPRequestCallback() {
            @Override
            public void onRequestFinished(int i11, int i12, String str3) {
                SuperSoundJni.supersound_on_http_request_finished(j11, j10, i11, i12, str3);
            }
        });
    }

    public static void initConfigFinish(int i10, int i11) {
        if (SuperSoundConfigure.getAsyncCallBack() != null) {
            SuperSoundConfigure.getAsyncCallBack().onAsyncCallBack(i10, "");
        }
        SuperSoundConfigure.getLogProxy().i(TAG, "initConfigFinish type:" + i10 + " errorCode:" + i11);
    }

    public static boolean mkdir(String str) {
        File file = new File(str);
        boolean zMkdirs = file.mkdirs();
        SuperSoundConfigure.getLogProxy().i(TAG, "mkdirs:" + zMkdirs + " " + str + " exist:" + file.exists() + " dir:" + file.isDirectory());
        return zMkdirs;
    }

    public static void onSetEffectCallback(int i10, int i11, int i12) {
        SuperSoundConfigure.SetEffectCallback setEffectCallback = SuperSoundConfigure.getSetEffectCallback();
        if (setEffectCallback != null) {
            setEffectCallback.onSetEffectCallback(i10, i11, i12);
        }
    }

    public static native long rubber_band_create_inst(int i10, int i11);

    public static native void rubber_band_destroy_inst(long j10);

    public static native void rubber_band_flush_out(long j10);

    public static native int rubber_band_process_in(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int rubber_band_process_out(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int rubber_band_processf_in(long j10, float[] fArr, int i10, int[] iArr);

    public static native int rubber_band_processf_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native void rubber_band_set_pitch_parameters(long j10, float f10);

    public static void setSP(String str, String str2) {
        SuperSoundConfigure.SPListener sPListener = SuperSoundConfigure.getSPListener();
        if (sPListener != null) {
            sPListener.setSP(str, str2);
        }
    }

    public static native boolean ss_bs_check_resource(String str);

    public static native long ss_bs_create_inst(String str, int i10, int i11, float f10);

    public static native void ss_bs_destroy_inst(long j10);

    public static native int ss_bs_process_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_bs_update_params(long j10, String str, String[] strArr);

    public static native int ss_bw_test(String[] strArr, String[] strArr2);

    public static native long ss_multi_track_create_inst(int i10, int i11, int i12);

    public static native int ss_multi_track_destroy_inst(long j10);

    public static native int ss_multi_track_get_current_tid();

    public static native String ss_multi_track_get_res(boolean z10);

    public static native int ss_multi_track_init_res();

    public static native int ss_multi_track_process_in(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_multi_track_process_out(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_multi_track_processf_in(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_multi_track_processf_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_multi_track_reset(int i10);

    public static native int ss_multi_track_set_param(long j10, String str);

    public static native long ss_mw_create_inst(int i10, int i11, String str);

    public static native void ss_mw_destroy_inst(long j10);

    public static native int ss_mw_flush_out(long j10);

    public static native int ss_mw_process_in(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_mw_process_out(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_mw_processf_in(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_mw_processf_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_mw_seek(long j10, long j11);

    public static native int ss_mw_set_effect_from_json(long j10, String str, SSMirInfoItem sSMirInfoItem, int[] iArr);

    public static native int ss_psctrl_begin_remix(long j10);

    public static native long ss_psctrl_create_inst(int i10, int i11, float f10, int i12);

    public static native void ss_psctrl_destroy_inst(long j10);

    public static native int ss_psctrl_end_remix(long j10);

    public static native int ss_psctrl_get_actual_time(long j10, long j11);

    public static native String ss_psctrl_get_playspeed_report_string(long j10);

    public static native String ss_psctrl_get_remix_info(long j10);

    public static native String ss_psctrl_get_remix_report_string(long j10);

    public static native float ss_psctrl_get_remix_speed(long j10);

    public static native SSDJTemplatePresetItem[] ss_psctrl_get_template_preset_item();

    public static native int ss_psctrl_process_input(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_psctrl_process_output(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_psctrl_processf_input(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_psctrl_processf_output(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_psctrl_seek(long j10, long j11);

    public static native int ss_psctrl_set_dj_proj_path(long j10, String str);

    public static native int ss_psctrl_set_loop_dir(String str);

    public static native int ss_psctrl_set_mir_info(long j10, float f10, float[] fArr, int i10, float[] fArr2, int[] iArr, float[] fArr3, String[] strArr, int i11, int i12, int i13, float[] fArr4);

    public static native int ss_psctrl_set_multiple(long j10, float f10);

    public static native int ss_psctrl_set_template_name(long j10, String str);

    public static native int ss_psctrl_set_type_id(long j10, int i10, int i11);

    public static native long ss_spatial_audio_create_inst(int i10, int i11, int i12);

    public static native int ss_spatial_audio_create_major_sound_obj_source(long j10, int i10, int i11, int i12, int[] iArr);

    public static native int ss_spatial_audio_create_sound_obj_source(long j10, String[] strArr);

    public static native void ss_spatial_audio_destroy_inst(long j10);

    public static native void ss_spatial_audio_destroy_source(long j10, int i10);

    public static native boolean ss_spatial_audio_enable_sound_obj_source(long j10, int i10, boolean z10);

    public static native int ss_spatial_audio_flush_out(long j10);

    public static native int ss_spatial_audio_process_in(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_spatial_audio_process_out(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_spatial_audio_processf_in(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_spatial_audio_processf_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_spatial_audio_set_car_aep_paths(long j10, String[] strArr, int i10);

    public static native boolean ss_spatial_audio_set_comm_param(long j10, float f10, float[] fArr, float[] fArr2, float f11, float[] fArr3, float f12, float[] fArr4);

    public static native boolean ss_spatial_audio_set_source_parameter(long j10, int i10, float[] fArr, float f10);

    public static native int ss_spatial_audio_set_sources_parameters(long j10, int[] iArr, float[] fArr);

    public static native int ss_spatial_modify_complete(long j10);

    public static native long ss_vocal_accomp_mix_create_inst(int i10, int i11);

    public static native void ss_vocal_accomp_mix_destroy_inst(long j10);

    public static native int ss_vocal_accomp_mix_flush_out(long j10);

    public static native int ss_vocal_accomp_mix_process_in(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_vocal_accomp_mix_process_out(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int ss_vocal_accomp_mix_processf_in(long j10, float[] fArr, int i10, int[] iArr);

    public static native int ss_vocal_accomp_mix_processf_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native void ss_vocal_accomp_mix_set_weight(long j10, float f10, float f11);

    public static void superSoundLog(int i10, String str) {
        if (i10 == 1) {
            SuperSoundConfigure.getLogProxy().d("SS2#SuperSoundLog", str);
            return;
        }
        if (i10 == 2) {
            SuperSoundConfigure.getLogProxy().i("SS2#SuperSoundLog", str);
        } else if (i10 == 4 || i10 == 8) {
            SuperSoundConfigure.getLogProxy().e("SS2#SuperSoundLog", str);
        }
    }

    public static native SSCustomAddRtItem supersound_add_custom_item(SSCreateCustomItem sSCreateCustomItem);

    public static native int supersound_add_custom_room_item(SSCreateCustomRoomItem sSCreateCustomRoomItem);

    public static native int supersound_add_ear_print_item(SSEarPrintItem sSEarPrintItem);

    public static native int supersound_calculate_roomeq(String str, String str2, float f10);

    public static native int supersound_car_effect_set_eq10_value(int i10, float[] fArr);

    public static native boolean supersound_check_is_local_path_valid();

    public static native int supersound_config_item_set(int i10, int i11, String str, float f10);

    public static native long supersound_create_ae_inst(int i10);

    public static native long supersound_create_inst(int i10, int i11);

    public static native int supersound_custom_item_set(int i10, String str, String str2);

    public static native int supersound_custom_room_item_set(int i10, String str, String str2);

    public static native int supersound_custom_room_item_set_seat_status(int i10, int[] iArr);

    public static native int supersound_custom_room_item_set_temp(int i10, boolean z10);

    public static native int supersound_delete_custom_item(int i10);

    public static native int supersound_delete_custom_room_item(int i10);

    public static native int supersound_delete_ear_print_item(int i10);

    public static native void supersound_destory_inst(long j10);

    public static native int supersound_download_config(int i10);

    public static native int supersound_download_device_config(int i10, boolean z10);

    public static native int supersound_ear_print_item_set(int i10, String str, String str2);

    public static native int supersound_effect_modify_complete(long j10);

    public static native void supersound_flush_out(long j10);

    public static native int supersound_get_cached_samples(long j10);

    public static native SSDeviceModelItem[] supersound_get_car_child_item_list(int i10);

    public static native SSDeviceVendorItem[] supersound_get_car_item_list();

    public static native SSCustomItem[] supersound_get_custom_item_list();

    public static native SSCustomRoomItem supersound_get_custom_room_item(int i10);

    public static native SSCustomRoomItem[] supersound_get_custom_room_item_list();

    public static native SSDtsEffectItem[] supersound_get_dts_item_list();

    public static native SSEarPrintItem[] supersound_get_ear_print_item_list();

    public static native SSEditableEffectParamItem[] supersound_get_editable_effect_param_item_list(int i10);

    public static native SSEditableEffectPresetItem[] supersound_get_editable_effect_preset_item_list(int i10);

    public static native SSUGCEffectItem[] supersound_get_env_effect_item_list();

    public static native SSEQItem[] supersound_get_eq_item_list();

    public static native int supersound_get_flatbuffer_version();

    public static native SSFocusMapItem[] supersound_get_focus_map_item_list();

    public static native SSDeviceModelItem[] supersound_get_headphone_child_item_list(int i10);

    public static native SSDeviceVendorItem[] supersound_get_headphone_item_list();

    public static native byte[] supersound_get_open_effect_flat_buffer(long j10);

    public static native SSRecommendItem[] supersound_get_recommend_item_list();

    public static native SSRecommendItem[] supersound_get_recommend_tag_child_item_list(int i10);

    public static native SSRecommendTagItem[] supersound_get_recommend_tag_item_list();

    public static native String supersound_get_report_string(long j10);

    public static native SSShakeLightItem[] supersound_get_shake_light_item_list();

    public static native SSSingerEffectItem[] supersound_get_singer_item_list();

    public static native SSDeviceModelItem[] supersound_get_soundbox_child_item_list(int i10);

    public static native SSDeviceVendorItem[] supersound_get_soundbox_item_list();

    public static native SSSpeakerItem[] supersound_get_speaker_item_list();

    public static native SSUGCEffectItem[] supersound_get_ugc_effect_item_list();

    public static native int supersound_get_vesion();

    public static native long supersound_hrs_create_inst(int i10, int i11, int i12, int i13, String str, String str2, String str3, float f10, int[] iArr);

    public static native void supersound_hrs_destroy_inst(long j10);

    public static native int supersound_hrs_process_in(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int supersound_hrs_process_out(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int supersound_hrs_processf_in(long j10, float[] fArr, int i10, int[] iArr);

    public static native int supersound_hrs_processf_out(long j10, float[] fArr, int i10, int[] iArr);

    public static native int supersound_hrs_set_control_flag(long j10, boolean z10, boolean z11);

    public static native int supersound_hsr_flush_out(long j10);

    public static native int supersound_hsr_nn_active(long j10);

    public static native int supersound_hsr_reset_param(long j10, int i10, int i11);

    public static native int supersound_hsr_set_protection_param(long j10, int i10, float f10, int i11);

    public static native int supersound_init(int i10);

    public static native int supersound_init_audio_effect(long j10, String str, byte[] bArr);

    public static native boolean supersound_init_path(String str, String str2);

    public static native int supersound_item_set(long j10, int i10, String str, String str2);

    public static native int supersound_item_set_params(long j10, int i10, String[] strArr, float[] fArr);

    public static native int supersound_load_aep_set_params(long j10, String str);

    public static native void supersound_on_download_finished(long j10, long j11, int i10, int i11, String str, String str2);

    public static native void supersound_on_http_request_finished(long j10, long j11, int i10, int i11, String str);

    public static native void supersound_on_unite_http_request_finished(long j10, long j11, int i10, String str);

    public static native int supersound_process_all(long j10, byte[] bArr, int i10, int[] iArr);

    public static native int supersound_process_in(long j10, short[] sArr, int i10, int[] iArr);

    public static native int supersound_process_out(long j10, short[] sArr, int i10, int[] iArr);

    public static native int supersound_processf_all(long j10, float[] fArr, int i10, int[] iArr);

    public static native boolean supersound_register_func();

    public static native int supersound_remove_effect(long j10, int i10);

    public static native int supersound_request_effect_data(int i10, boolean z10);

    public static native int supersound_seek(long j10, long j11);

    public static native int supersound_set_ae_effect(long j10, long[] jArr);

    public static native int supersound_set_custom_eq_item_param(String str, float f10);

    public static native int supersound_set_editable_effect_bytes_param(int i10, String str, byte[] bArr);

    public static native int supersound_set_editable_effect_param(int i10, String str, float f10);

    public static native int supersound_set_editable_effect_string_param(int i10, String str, String str2);

    public static native int supersound_set_effect(long j10, int i10, int i11);

    public static native boolean supersound_set_env_effect_root_dir(String str);

    public static native void supersound_set_log_level(int i10);

    public static native int supersound_set_modulator(String str, double d10);

    public static native boolean supersound_set_ugc_effect_root_dir(String str);

    public static native int supersound_set_user_id(String str);

    public static void uniteHttpRequest(String str, String str2, String str3, final long j10, final long j11) {
        SuperSoundConfigure.getLogProxy().i(TAG, "uniteHttpRequest moudle" + str + "method" + str2 + " content:" + str3 + " userData:" + j10);
        SuperSoundConfigure.getUniteHttpRequest().requestUnite(str, str2, str3, new SuperSoundConfigure.UniteHTTPRequestCallback() {
            @Override
            public void onUniteRequestFinished(int i10, String str4) {
                SuperSoundJni.supersound_on_unite_http_request_finished(j11, j10, i10, str4);
            }
        });
    }

    public static void unzip(String str, String str2) {
        SuperSoundConfigure.getLogProxy().i(TAG, "unzip srcPath:" + str + " destinationPath:" + str2);
        ZipUtils.unzip(str, str2);
    }
}
