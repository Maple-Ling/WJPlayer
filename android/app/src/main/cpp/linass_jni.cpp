#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <android/log.h>

#define LOG_TAG "LinassJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================================
// libass 类型定义（从 libass 头文件提取的最小定义）
// ============================================================================

typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;

typedef struct ass_image {
    int w, h;
    int stride;
    unsigned char *bitmap;
    uint32_t color;
    int dst_x, dst_y;
    struct ass_image *next;
} ASS_Image;

// ============================================================================
// 函数指针（从 libass.so 或 libmpv.so 动态加载）
// ============================================================================

static struct {
    void *handle;

    ASS_Library* (*ass_library_init)(void);
    void (*ass_library_done)(ASS_Library *priv);
    void (*ass_set_extract_fonts)(ASS_Library *priv, int extract);
    void (*ass_set_style_overrides)(ASS_Library *priv, char **list);

    ASS_Renderer* (*ass_renderer_init)(ASS_Library *);
    void (*ass_renderer_done)(ASS_Renderer *priv);
    void (*ass_set_frame_size)(ASS_Renderer *priv, int w, int h);
    void (*ass_set_storage_size)(ASS_Renderer *priv, int w, int h);
    void (*ass_set_use_margins)(ASS_Renderer *priv, int use);
    void (*ass_set_font_scale)(ASS_Renderer *priv, double font_scale);
    void (*ass_set_hinting)(ASS_Renderer *priv, int hinting);
    void (*ass_set_line_spacing)(ASS_Renderer *priv, double line_spacing);
    void (*ass_set_default_font)(ASS_Renderer *priv, const char *default_font,
                                 const char *default_family);

    ASS_Track* (*ass_read_file)(ASS_Library *library, char *fname, char *codepage);
    ASS_Track* (*ass_read_memory)(ASS_Library *library, char *buf, size_t bufsize,
                                  char *codepage);
    void (*ass_free_track)(ASS_Track *track);

    ASS_Image* (*ass_render_frame)(ASS_Renderer *priv, ASS_Track *track,
                                   long long now, int *detect_change);

    int available;
} g_ass = {NULL};

static struct {
    ASS_Library *library;
    ASS_Renderer *renderer;
    ASS_Track *track;
} g_ctx = {NULL, NULL, NULL};

// ============================================================================
// 动态加载 libass 符号
// ============================================================================

static int load_libass_symbols(void *handle) {
    #define LOAD_SYM(name) \
        g_ass.name = (decltype(g_ass.name))dlsym(handle, #name); \
        if (!g_ass.name) { \
            LOGE("Failed to load symbol: " #name); \
            return 0; \
        }

    LOAD_SYM(ass_library_init)
    LOAD_SYM(ass_library_done)
    LOAD_SYM(ass_set_extract_fonts)
    LOAD_SYM(ass_set_style_overrides)
    LOAD_SYM(ass_renderer_init)
    LOAD_SYM(ass_renderer_done)
    LOAD_SYM(ass_set_frame_size)
    LOAD_SYM(ass_set_storage_size)
    LOAD_SYM(ass_set_use_margins)
    LOAD_SYM(ass_set_font_scale)
    LOAD_SYM(ass_set_hinting)
    LOAD_SYM(ass_set_line_spacing)
    LOAD_SYM(ass_set_default_font)
    LOAD_SYM(ass_read_file)
    LOAD_SYM(ass_read_memory)
    LOAD_SYM(ass_free_track)
    LOAD_SYM(ass_render_frame)

    #undef LOAD_SYM
    return 1;
}

// 由Java层传入的so文件路径
static char g_libass_path[512] = {0};
static char g_libmpv_path[512] = {0};

extern "C" JNIEXPORT void JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeSetLibraryPaths(JNIEnv *env, jobject thiz, jstring libassPath, jstring libmpvPath) {
    const char *assPath = env->GetStringUTFChars(libassPath, NULL);
    const char *mpvPath = env->GetStringUTFChars(libmpvPath, NULL);
    if (assPath) {
        strncpy(g_libass_path, assPath, sizeof(g_libass_path) - 1);
        g_libass_path[sizeof(g_libass_path) - 1] = '\0';
    }
    if (mpvPath) {
        strncpy(g_libmpv_path, mpvPath, sizeof(g_libmpv_path) - 1);
        g_libmpv_path[sizeof(g_libmpv_path) - 1] = '\0';
    }
    if (assPath) env->ReleaseStringUTFChars(libassPath, assPath);
    if (mpvPath) env->ReleaseStringUTFChars(libmpvPath, mpvPath);
    LOGI("Library paths set: ass=%s, mpv=%s", g_libass_path, g_libmpv_path);
}

static void init_libass() {
    if (g_ass.available) return;

    LOGI("Initializing libass...");
    LOGI("Paths: ass='%s', mpv='%s'", g_libass_path, g_libmpv_path);

    // 策略1：使用 RTLD_DEFAULT 搜索所有已加载的库（包括 media_kit 加载的 libmpv.so）
    // media_kit 用 RTLD_LOCAL 加载 libmpv.so，符号默认不可见，但 RTLD_DEFAULT 可以搜索到
    LOGI("Trying RTLD_DEFAULT to find libass symbols in already-loaded libraries...");
    if (load_libass_symbols(RTLD_DEFAULT)) {
        g_ass.available = 1;
        g_ass.handle = RTLD_DEFAULT;
        LOGI("libass symbols found via RTLD_DEFAULT (likely from media_kit's libmpv.so)");
        return;
    }
    LOGI("No libass symbols found via RTLD_DEFAULT");

    // 策略2：优先使用Java层传入的完整路径（如果存在）
    if (g_libass_path[0] != '\0') {
        g_ass.handle = dlopen(g_libass_path, RTLD_NOW | RTLD_GLOBAL);
        if (g_ass.handle) {
            LOGI("Loaded libass.so from: %s", g_libass_path);
        } else {
            LOGE("Failed to load libass.so from: %s, error=%s", g_libass_path, dlerror());
        }
    }
    
    if (!g_ass.handle && g_libmpv_path[0] != '\0') {
        g_ass.handle = dlopen(g_libmpv_path, RTLD_NOW | RTLD_GLOBAL);
        if (g_ass.handle) {
            LOGI("Loaded libmpv.so from: %s", g_libmpv_path);
        } else {
            LOGE("Failed to load libmpv.so from: %s, error=%s", g_libmpv_path, dlerror());
        }
    }

    // 策略3：尝试dlopen(NULL)获取全局符号
    if (!g_ass.handle) {
        void* global_handle = dlopen(NULL, RTLD_NOW | RTLD_GLOBAL);
        if (global_handle) {
            LOGI("Trying to load libass symbols from global scope...");
            if (load_libass_symbols(global_handle)) {
                g_ass.available = 1;
                g_ass.handle = global_handle;
                LOGI("libass symbols loaded from global scope");
                return;
            }
            LOGI("No libass symbols found in global scope");
        }
    }

    // 策略4：尝试从系统库路径加载
    if (!g_ass.handle) {
        g_ass.handle = dlopen("libass.so", RTLD_NOW | RTLD_GLOBAL);
        if (g_ass.handle) {
            LOGI("Loaded libass.so from system path");
        } else {
            LOGI("libass.so not found in system path: %s", dlerror());
        }
    }

    // 策略5：尝试加载 libmpv.so
    if (!g_ass.handle) {
        g_ass.handle = dlopen("libmpv.so", RTLD_NOW | RTLD_GLOBAL);
        if (g_ass.handle) {
            LOGI("Loaded libmpv.so from system path");
        } else {
            LOGI("libmpv.so not found in system path: %s", dlerror());
        }
    }

    if (!g_ass.handle) {
        LOGE("Could not load any library containing libass symbols");
        return;
    }

    if (load_libass_symbols(g_ass.handle)) {
        g_ass.available = 1;
        LOGI("libass symbols loaded successfully");
    } else {
        if (g_ass.handle != RTLD_DEFAULT) {
            dlclose(g_ass.handle);
        }
        g_ass.handle = NULL;
        LOGE("Failed to load libass symbols from loaded library");
    }
}

// ============================================================================
// JNI 实现（C++ 语法：env->...）
// ============================================================================

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeIsAvailable(JNIEnv *env, jobject thiz) {
    init_libass();
    return g_ass.available ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeInit(JNIEnv *env, jobject thiz, jint width, jint height) {
    init_libass();
    if (!g_ass.available) {
        LOGE("libass not available");
        return 0;
    }

    if (g_ctx.library) {
        g_ass.ass_library_done(g_ctx.library);
    }
    if (g_ctx.renderer) {
        g_ass.ass_renderer_done(g_ctx.renderer);
    }

    g_ctx.library = g_ass.ass_library_init();
    if (!g_ctx.library) {
        LOGE("Failed to init ass_library");
        return 0;
    }

    g_ass.ass_set_extract_fonts(g_ctx.library, 1);
    g_ass.ass_set_style_overrides(g_ctx.library, NULL);

    g_ctx.renderer = g_ass.ass_renderer_init(g_ctx.library);
    if (!g_ctx.renderer) {
        LOGE("Failed to init ass_renderer");
        g_ass.ass_library_done(g_ctx.library);
        g_ctx.library = NULL;
        return 0;
    }

    g_ass.ass_set_frame_size(g_ctx.renderer, width, height);
    g_ass.ass_set_storage_size(g_ctx.renderer, width, height);
    g_ass.ass_set_use_margins(g_ctx.renderer, 0);
    g_ass.ass_set_font_scale(g_ctx.renderer, 1.0);
    g_ass.ass_set_hinting(g_ctx.renderer, 1); // ASS_HINTING_LIGHT
    g_ass.ass_set_line_spacing(g_ctx.renderer, 0.0);

    LOGI("libass init: %dx%d", width, height);
    return (jlong)(intptr_t)g_ctx.library;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeLoadFile(JNIEnv *env, jobject thiz, jlong handle, jstring path) {
    if (!g_ass.available || !g_ctx.library) return 0;
    const char *cpath = env->GetStringUTFChars(path, NULL);
    g_ctx.track = g_ass.ass_read_file(g_ctx.library, (char *)cpath, NULL);
    env->ReleaseStringUTFChars(path, cpath);
    if (!g_ctx.track) {
        LOGE("Failed to load sub file");
        return 0;
    }
    LOGI("Loaded sub file");
    return (jlong)(intptr_t)g_ctx.track;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeLoadMemory(JNIEnv *env, jobject thiz, jlong handle, jbyteArray data, jstring codec) {
    if (!g_ass.available || !g_ctx.library) return 0;
    jsize len = env->GetArrayLength(data);
    jbyte *buf = env->GetByteArrayElements(data, NULL);
    const char *ccodec = env->GetStringUTFChars(codec, NULL);

    g_ctx.track = g_ass.ass_read_memory(g_ctx.library, (char *)buf, (size_t)len, (char *)ccodec);

    env->ReleaseByteArrayElements(data, buf, JNI_ABORT);
    env->ReleaseStringUTFChars(codec, ccodec);

    if (!g_ctx.track) {
        LOGE("Failed to load sub from memory");
        return 0;
    }
    LOGI("Loaded sub memory");
    return (jlong)(intptr_t)g_ctx.track;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeSetFontSize(JNIEnv *env, jobject thiz, jlong handle, jint size) {
    if (!g_ass.available || !g_ctx.renderer) return;
    g_ass.ass_set_font_scale(g_ctx.renderer, (double)size / 48.0);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeSetFontName(JNIEnv *env, jobject thiz, jlong handle, jstring name) {
    if (!g_ass.available || !g_ctx.renderer) return;
    const char *cname = env->GetStringUTFChars(name, NULL);
    g_ass.ass_set_default_font(g_ctx.renderer, cname, NULL);
    env->ReleaseStringUTFChars(name, cname);
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeRenderFrame(JNIEnv *env, jobject thiz, jlong rhandle, jlong thandle, jlong ptsMs) {
    if (!g_ass.available || !g_ctx.renderer || !g_ctx.track) return NULL;

    int changed = 0;
    ASS_Image *img = g_ass.ass_render_frame(g_ctx.renderer, g_ctx.track, ptsMs * 1000, &changed);

    if (!img) return NULL;

    int totalSize = 0;
    ASS_Image *cur = img;
    while (cur) {
        totalSize += cur->w * cur->h * 4 + 20; // 4 ints: w, h, stride, dst_x, dst_y
        cur = cur->next;
    }
    if (totalSize == 0) return NULL;

    jbyteArray result = env->NewByteArray(totalSize);
    jbyte *out = env->GetByteArrayElements(result, NULL);
    int offset = 0;

    cur = img;
    while (cur) {
        int w = cur->w;
        int h = cur->h;
        int stride = cur->stride;
        int dst_x = cur->dst_x;
        int dst_y = cur->dst_y;
        unsigned int color = cur->color;
        unsigned char r = (color >> 24) & 0xFF;
        unsigned char g = (color >> 16) & 0xFF;
        unsigned char b = (color >> 8) & 0xFF;
        unsigned char a = (color) & 0xFF;

        ((int *)out)[offset / 4] = w; offset += 4;
        ((int *)out)[offset / 4] = h; offset += 4;
        ((int *)out)[offset / 4] = stride; offset += 4;
        ((int *)out)[offset / 4] = dst_x; offset += 4;
        ((int *)out)[offset / 4] = dst_y; offset += 4;

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                unsigned char alpha = cur->bitmap[y * stride + x];
                out[offset++] = r;
                out[offset++] = g;
                out[offset++] = b;
                out[offset++] = (unsigned char)((alpha * (255 - a)) / 255);
            }
        }
        cur = cur->next;
    }

    env->ReleaseByteArrayElements(result, out, 0);
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_wjplayer_1mobile_LibassBridge_nativeDispose(JNIEnv *env, jobject thiz, jlong lhandle, jlong rhandle, jlong thandle) {
    if (!g_ass.available) return;
    if (g_ctx.track) {
        g_ass.ass_free_track(g_ctx.track);
        g_ctx.track = NULL;
    }
    if (g_ctx.renderer) {
        g_ass.ass_renderer_done(g_ctx.renderer);
        g_ctx.renderer = NULL;
    }
    if (g_ctx.library) {
        g_ass.ass_library_done(g_ctx.library);
        g_ctx.library = NULL;
    }
    LOGI("libass disposed");
}
