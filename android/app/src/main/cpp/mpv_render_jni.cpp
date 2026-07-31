#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <android/log.h>
#include <atomic>
#include <thread>
#include <unistd.h>

#define LOG_TAG "MpvRenderJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

struct RenderContext {
    mpv_handle *mpv;
    mpv_render_context *render_ctx;
    EGLDisplay egl_display;
    EGLContext egl_context;
    EGLSurface egl_surface;
    ANativeWindow *window;
    int width;
    int height;
    std::atomic<bool> running{false};
    std::atomic<bool> needs_render{false};
    std::thread render_thread;
};

static void *get_proc_address(void *fn_ctx, const char *name) {
    (void)fn_ctx;
    void *addr = (void*)eglGetProcAddress(name);
    if (!addr) {
        LOGE("Failed to get GL proc address: %s", name);
    }
    return addr;
}

static void render_loop(RenderContext *ctx) {
    LOGI("Render loop started");
    
    while (ctx->running.load()) {
        if (ctx->needs_render.load()) {
            ctx->needs_render.store(false);
            
            if (!eglMakeCurrent(ctx->egl_display, ctx->egl_surface, ctx->egl_surface, ctx->egl_context)) {
                LOGE("Failed to make EGL current");
                continue;
            }
            
            int flip_y = 1;
            mpv_opengl_fbo fbo = {
                .fbo = 0,
                .w = ctx->width,
                .h = ctx->height,
                .internal_format = 0,
            };
            
            mpv_render_param params[] = {
                {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
                {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
                {MPV_RENDER_PARAM_INVALID, nullptr}
            };
            
            mpv_render_context_render(ctx->render_ctx, params);
            eglSwapBuffers(ctx->egl_display, ctx->egl_surface);
        }
        
        usleep(16000); // ~60fps polling
    }
    
    LOGI("Render loop stopped");
}

static void on_mpv_update(void *ctx_ptr) {
    auto *ctx = static_cast<RenderContext*>(ctx_ptr);
    ctx->needs_render.store(true);
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_wjplayer_1mobile_MpvTexture_nativeCreateRenderContext(
    JNIEnv *env, jobject thiz, jlong mpv_handle_ptr, jobject surface) {
    
    auto *mpv = reinterpret_cast<mpv_handle*>(mpv_handle_ptr);
    if (!mpv) {
        LOGE("Invalid mpv handle");
        return 0;
    }
    
    auto *ctx = new RenderContext();
    ctx->mpv = mpv;
    
    ctx->window = ANativeWindow_fromSurface(env, surface);
    if (!ctx->window) {
        LOGE("Failed to get ANativeWindow from surface");
        delete ctx;
        return 0;
    }
    
    ctx->width = ANativeWindow_getWidth(ctx->window);
    ctx->height = ANativeWindow_getHeight(ctx->window);
    LOGI("Window size: %dx%d", ctx->width, ctx->height);
    
    ctx->egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (ctx->egl_display == EGL_NO_DISPLAY) {
        LOGE("Failed to get EGL display");
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    
    EGLint major, minor;
    if (!eglInitialize(ctx->egl_display, &major, &minor)) {
        LOGE("Failed to initialize EGL");
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    LOGI("EGL version: %d.%d", major, minor);
    
    const EGLint configAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0,
        EGL_STENCIL_SIZE, 0,
        EGL_NONE
    };
    
    EGLConfig config;
    EGLint numConfigs;
    if (!eglChooseConfig(ctx->egl_display, configAttribs, &config, 1, &numConfigs) || numConfigs < 1) {
        LOGE("Failed to choose EGL config");
        eglTerminate(ctx->egl_display);
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    
    const EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE
    };
    ctx->egl_context = eglCreateContext(ctx->egl_display, config, EGL_NO_CONTEXT, contextAttribs);
    if (ctx->egl_context == EGL_NO_CONTEXT) {
        LOGE("Failed to create EGL context");
        eglTerminate(ctx->egl_display);
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    
    ctx->egl_surface = eglCreateWindowSurface(ctx->egl_display, config, ctx->window, nullptr);
    if (ctx->egl_surface == EGL_NO_SURFACE) {
        LOGE("Failed to create EGL surface");
        eglDestroyContext(ctx->egl_display, ctx->egl_context);
        eglTerminate(ctx->egl_display);
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    
    if (!eglMakeCurrent(ctx->egl_display, ctx->egl_surface, ctx->egl_surface, ctx->egl_context)) {
        LOGE("Failed to make EGL current");
        eglDestroySurface(ctx->egl_display, ctx->egl_surface);
        eglDestroyContext(ctx->egl_display, ctx->egl_context);
        eglTerminate(ctx->egl_display);
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    
    mpv_opengl_init_params gl_init_params = {
        .get_proc_address = get_proc_address,
        .get_proc_address_ctx = nullptr,
        .extra_exts = nullptr,
    };
    
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL_ES},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params},
        {MPV_RENDER_PARAM_INVALID, nullptr}
    };
    
    int err = mpv_render_context_create(&ctx->render_ctx, mpv, params);
    if (err < 0) {
        LOGE("Failed to create mpv render context: %d", err);
        eglMakeCurrent(ctx->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(ctx->egl_display, ctx->egl_surface);
        eglDestroyContext(ctx->egl_display, ctx->egl_context);
        eglTerminate(ctx->egl_display);
        ANativeWindow_release(ctx->window);
        delete ctx;
        return 0;
    }
    
    mpv_render_context_set_update_callback(ctx->render_ctx, on_mpv_update, ctx);
    
    ctx->running.store(true);
    ctx->render_thread = std::thread(render_loop, ctx);
    
    LOGI("MPV render context created successfully");
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_wjplayer_1mobile_MpvTexture_nativeDestroyRenderContext(
    JNIEnv *env, jobject thiz, jlong render_ctx_handle) {
    
    auto *ctx = reinterpret_cast<RenderContext*>(render_ctx_handle);
    if (!ctx) return;
    
    ctx->running.store(false);
    if (ctx->render_thread.joinable()) {
        ctx->render_thread.join();
    }
    
    if (ctx->render_ctx) {
        mpv_render_context_free(ctx->render_ctx);
    }
    
    if (ctx->egl_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(ctx->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (ctx->egl_surface != EGL_NO_SURFACE) {
            eglDestroySurface(ctx->egl_display, ctx->egl_surface);
        }
        if (ctx->egl_context != EGL_NO_CONTEXT) {
            eglDestroyContext(ctx->egl_display, ctx->egl_context);
        }
        eglTerminate(ctx->egl_display);
    }
    
    if (ctx->window) {
        ANativeWindow_release(ctx->window);
    }
    
    delete ctx;
    LOGI("MPV render context destroyed");
}
