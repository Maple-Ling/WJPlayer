/**
 * mpv_init_jni.cpp — JNI initialization bridge for mpv on Android.
 *
 * Caches the JavaVM pointer in JNI_OnLoad, then registers it with
 * mpv via mpv_lavc_set_java_vm (mpv's own exported function).
 */
#include <jni.h>
#include <dlfcn.h>
#include <android/log.h>

#define TAG "MpvInitJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static JavaVM *g_cached_vm = nullptr;

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    LOGI("JNI_OnLoad: caching JavaVM %p", vm);
    g_cached_vm = vm;
    return JNI_VERSION_1_6;
}

/**
 * Register the cached JavaVM with mpv/libavcodec.
 * Uses mpv_lavc_set_java_vm from libmpv.so (not av_jni_set_java_vm from
 * libavcodec.so) to avoid Android linker namespace isolation issues.
 */
extern "C" JNIEXPORT void JNICALL
Java_com_example_wjplayer_1mobile_MpvInitBridge_nativeRegisterJavaVm(
    JNIEnv *env, jclass clazz) {
    if (!g_cached_vm) {
        LOGE("nativeRegisterJavaVm: no cached JavaVM!");
        return;
    }

    // Use mpv_lavc_set_java_vm which is exported by libmpv.so.
    // This correctly sets the JavaVM within libmpv.so's own ffmpeg copy,
    // avoiding the namespace isolation issue with dlsym on libavcodec.so.
    void *handle = dlopen("libmpv.so", RTLD_LAZY | RTLD_NOLOAD);
    if (!handle) {
        handle = dlopen("libmpv.so", RTLD_LAZY);
    }
    if (!handle) {
        LOGE("nativeRegisterJavaVm: dlopen(libmpv.so) failed: %s", dlerror());
        return;
    }

    typedef int (*mpv_lavc_set_java_vm_func)(void *vm);
    auto func = (mpv_lavc_set_java_vm_func)dlsym(handle, "mpv_lavc_set_java_vm");
    if (func) {
        int ret = func(g_cached_vm);
        LOGI("nativeRegisterJavaVm: mpv_lavc_set_java_vm(%p) = %d", g_cached_vm, ret);
    } else {
        LOGE("nativeRegisterJavaVm: mpv_lavc_set_java_vm not found: %s", dlerror());
        // Fallback: try av_jni_set_java_vm
        typedef void (*av_jni_set_java_vm_func)(JavaVM *, void *);
        auto av_func = (av_jni_set_java_vm_func)dlsym(handle, "av_jni_set_java_vm");
        if (av_func) {
            av_func(g_cached_vm, nullptr);
            LOGI("nativeRegisterJavaVm: fallback av_jni_set_java_vm done");
        } else {
            LOGE("nativeRegisterJavaVm: neither function found!");
        }
    }
}
