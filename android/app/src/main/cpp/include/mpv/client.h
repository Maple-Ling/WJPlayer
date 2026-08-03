#ifndef MPV_CLIENT_H_
#define MPV_CLIENT_H_

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct mpv_handle;
typedef struct mpv_handle mpv_handle;

typedef struct mpv_event {
    int event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} mpv_event;

struct mpv_handle *mpv_create(void);
int mpv_initialize(mpv_handle *ctx);
void mpv_terminate_destroy(mpv_handle *ctx);
int mpv_command_string(mpv_handle *ctx, const char *args);
int mpv_set_property_string(mpv_handle *ctx, const char *name, const char *data);
char *mpv_get_property_string(mpv_handle *ctx, const char *name);
void mpv_free(void *data);
int mpv_observe_property(mpv_handle *ctx, uint64_t reply_userdata, const char *name, int format);
int mpv_unobserve_property(mpv_handle *ctx, uint64_t registered_reply_userdata);
mpv_event *mpv_wait_event(mpv_handle *ctx, double timeout);
int mpv_request_log_messages(mpv_handle *ctx, const char *min_level);

#ifdef __cplusplus
}
#endif

#endif
