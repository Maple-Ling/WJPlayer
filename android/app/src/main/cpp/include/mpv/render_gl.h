#ifndef MPV_RENDER_GL_H_
#define MPV_RENDER_GL_H_

#include "client.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mpv_render_context mpv_render_context;

typedef void (*mpv_render_update_fn)(void *cb_ctx);
typedef void *(*mpv_get_proc_address_fn)(void *fn_ctx, const char *name);

typedef struct mpv_opengl_init_params {
    mpv_get_proc_address_fn get_proc_address;
    void *get_proc_address_ctx;
    const char *extra_exts;
} mpv_opengl_init_params;

typedef struct mpv_opengl_fbo {
    int fbo;
    int w;
    int h;
    int internal_format;
} mpv_opengl_fbo;

#define MPV_RENDER_API_TYPE_OPENGL "opengl"
#define MPV_RENDER_API_TYPE_OPENGL_ES "opengl-es"

enum mpv_render_param_type {
    MPV_RENDER_PARAM_INVALID = 0,
    MPV_RENDER_PARAM_API_TYPE = 1,
    MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2,
    MPV_RENDER_PARAM_OPENGL_FBO = 3,
    MPV_RENDER_PARAM_FLIP_Y = 4,
};

typedef struct mpv_render_param {
    int type;
    void *data;
} mpv_render_param;

int mpv_render_context_create(mpv_render_context **res, mpv_handle *mpv, mpv_render_param *params);
void mpv_render_context_set_update_callback(mpv_render_context *ctx, mpv_render_update_fn callback, void *callback_ctx);
void mpv_render_context_render(mpv_render_context *ctx, mpv_render_param *params);
void mpv_render_context_report_swap(mpv_render_context *ctx);
void mpv_render_context_free(mpv_render_context *ctx);

#ifdef __cplusplus
}
#endif

#endif
