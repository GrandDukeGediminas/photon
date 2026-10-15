// Spectrum capture for photon2 on Linux (photon_system.h, docs/linux-port.md §3.6).
#include "photon_system.h"

#include <pipewire/pipewire.h>
#include <pulse/error.h>
#include <pulse/simple.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/props.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct photon_capture {
    photon_capture_cb cb;
    void *context;
    const char *backend;
    int rate, channels;
    // PipeWire
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    struct spa_hook listener;
    volatile int negotiated, failed;
    // PulseAudio
    pa_simple *pa;
    pthread_t thread;
    volatile int running;
};

static void set_error(char *error, size_t size, const char *msg) {
    if (error && size > 0) snprintf(error, size, "%s", msg);
}

// MARK: - PipeWire

static void on_process(void *data) {
    photon_capture *c = data;
    struct pw_buffer *b = pw_stream_dequeue_buffer(c->stream);
    if (!b) return;
    struct spa_buffer *buf = b->buffer;
    if (buf->n_datas > 0 && buf->datas[0].data && c->channels > 0) {
        struct spa_data *d = &buf->datas[0];
        uint32_t offset = d->chunk->offset % (d->maxsize ? d->maxsize : 1);
        uint32_t size = d->chunk->size;
        if (offset + size > d->maxsize) size = d->maxsize - offset;
        uint32_t frames = size / (sizeof(float) * (uint32_t)c->channels);
        // One dequeued buffer is one packet, as one WASAPI GetBuffer is in the engine's capture loop.
        if (frames > 0) c->cb(c->context, (const float *)((const uint8_t *)d->data + offset), frames, (uint32_t)c->channels);
    }
    pw_stream_queue_buffer(c->stream, b);
}

static void on_param_changed(void *data, uint32_t id, const struct spa_pod *param) {
    photon_capture *c = data;
    if (!param || id != SPA_PARAM_Format) return;
    uint32_t media_type, media_subtype;
    if (spa_format_parse(param, &media_type, &media_subtype) < 0) return;
    if (media_type != SPA_MEDIA_TYPE_audio || media_subtype != SPA_MEDIA_SUBTYPE_raw) return;
    struct spa_audio_info_raw info;
    spa_zero(info);
    if (spa_format_audio_raw_parse(param, &info) < 0) return;
    c->rate = (int)info.rate;
    c->channels = (int)info.channels;
    c->negotiated = 1;
    pw_thread_loop_signal(c->loop, false);
}

static void on_state_changed(void *data, enum pw_stream_state old, enum pw_stream_state state, const char *error) {
    (void)old; (void)error;
    photon_capture *c = data;
    if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
        c->failed = 1;
        pw_thread_loop_signal(c->loop, false);
    }
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = on_state_changed,
    .param_changed = on_param_changed,
    .process = on_process,
};

static pthread_once_t pw_once = PTHREAD_ONCE_INIT;
static void pw_init_once(void) { pw_init(NULL, NULL); }

static void close_pipewire(photon_capture *c) {
    if (c->loop) pw_thread_loop_stop(c->loop);
    if (c->stream) pw_stream_destroy(c->stream);
    if (c->loop) pw_thread_loop_destroy(c->loop);
    c->stream = NULL;
    c->loop = NULL;
}

/// The default sink's monitor through a capture stream: float32 stereo at the graph rate (the WASAPI loopback mix
/// format is the device's float32 format at its own rate; the engine requires 32-bit float, docs/re/06 §5.1).
static int open_pipewire(photon_capture *c, char *error, size_t error_size) {
    pthread_once(&pw_once, pw_init_once);
    c->loop = pw_thread_loop_new("photon-capture", NULL);
    if (!c->loop) { set_error(error, error_size, "pw_thread_loop_new failed"); return 0; }
    struct pw_properties *props = pw_properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                    PW_KEY_MEDIA_ROLE, "Music", PW_KEY_STREAM_CAPTURE_SINK, "true",
                                                    PW_KEY_NODE_NAME, "photon2-spectrum", PW_KEY_APP_NAME, "photon2",
                                                    PW_KEY_NODE_DONT_RECONNECT, "false", NULL);
    pw_thread_loop_lock(c->loop);
    if (pw_thread_loop_start(c->loop) < 0) {
        pw_thread_loop_unlock(c->loop);
        close_pipewire(c);
        set_error(error, error_size, "pw_thread_loop_start failed");
        return 0;
    }
    c->stream = pw_stream_new_simple(pw_thread_loop_get_loop(c->loop), "photon2 spectrum", props, &stream_events, c);
    if (!c->stream) {
        pw_thread_loop_unlock(c->loop);
        close_pipewire(c);
        set_error(error, error_size, "no PipeWire daemon (pw_stream_new_simple failed)");
        return 0;
    }
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    struct spa_audio_info_raw info = SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .channels = 2);
    info.position[0] = SPA_AUDIO_CHANNEL_FL;
    info.position[1] = SPA_AUDIO_CHANNEL_FR;
    const struct spa_pod *params[1] = { spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info) };
    int r = pw_stream_connect(c->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                              PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, params, 1);
    if (r < 0) {
        pw_thread_loop_unlock(c->loop);
        close_pipewire(c);
        set_error(error, error_size, "pw_stream_connect failed (no PipeWire daemon?)");
        return 0;
    }
    // Wait for the format (links to the monitor are made by the session manager) or a failure, at most 3 s.
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += 3;
    while (!c->negotiated && !c->failed) {
        if (pw_thread_loop_timed_wait_full(c->loop, &deadline) != 0) break;
    }
    int ok = c->negotiated && !c->failed && c->rate > 0 && c->channels > 0;
    pw_thread_loop_unlock(c->loop);
    if (!ok) {
        close_pipewire(c);
        set_error(error, error_size, c->failed ? "PipeWire stream failed" : "PipeWire: no format negotiated within 3 s");
        return 0;
    }
    c->backend = "PipeWire";
    return 1;
}

// MARK: - PulseAudio

static void *pulse_thread(void *data) {
    photon_capture *c = data;
    enum { frames = 480 }; // 10 ms at 48 kHz, the record stream's fragment size
    float buf[frames * 2];
    while (c->running) {
        int err = 0;
        if (pa_simple_read(c->pa, buf, sizeof buf, &err) < 0) break;
        c->cb(c->context, buf, frames, 2);
    }
    return NULL;
}

/// `@DEFAULT_MONITOR@` at float32 stereo 48 kHz (the server resamples from the sink rate).
static int open_pulse(photon_capture *c, char *error, size_t error_size) {
    pa_sample_spec ss = { .format = PA_SAMPLE_FLOAT32LE, .rate = 48000, .channels = 2 };
    pa_buffer_attr attr = { .maxlength = (uint32_t)-1, .tlength = (uint32_t)-1, .prebuf = (uint32_t)-1,
                            .minreq = (uint32_t)-1, .fragsize = 480 * 2 * sizeof(float) };
    int err = 0;
    c->pa = pa_simple_new(NULL, "photon2", PA_STREAM_RECORD, "@DEFAULT_MONITOR@", "spectrum", &ss, NULL, &attr, &err);
    if (!c->pa) {
        char msg[160];
        snprintf(msg, sizeof msg, "PulseAudio: %s", pa_strerror(err));
        set_error(error, error_size, msg);
        return 0;
    }
    c->rate = 48000;
    c->channels = 2;
    c->running = 1;
    if (pthread_create(&c->thread, NULL, pulse_thread, c) != 0) {
        pa_simple_free(c->pa);
        c->pa = NULL;
        set_error(error, error_size, "pthread_create failed");
        return 0;
    }
    c->backend = "PulseAudio";
    return 1;
}

// MARK: - Interface

photon_capture *photon_capture_open(const char *backend, photon_capture_cb cb, void *context, char *error, size_t error_size) {
    photon_capture *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->cb = cb;
    c->context = context;
    char pwError[160] = "", paError[160] = "";
    int wantPW = !backend || !*backend || strcmp(backend, "pipewire") == 0;
    int wantPA = !backend || !*backend || strcmp(backend, "pulse") == 0;
    if (wantPW && open_pipewire(c, pwError, sizeof pwError)) return c;
    if (wantPA && open_pulse(c, paError, sizeof paError)) return c;
    if (error && error_size > 0) {
        snprintf(error, error_size, "%s%s%s", pwError, *pwError && *paError ? "; " : "", paError);
    }
    free(c);
    return NULL;
}

const char *photon_capture_backend(const photon_capture *c) { return c->backend; }
int photon_capture_rate(const photon_capture *c) { return c->rate; }
int photon_capture_channels(const photon_capture *c) { return c->channels; }

void photon_capture_close(photon_capture *c) {
    if (!c) return;
    if (c->loop) close_pipewire(c);
    if (c->pa) {
        c->running = 0;
        pthread_join(c->thread, NULL);
        pa_simple_free(c->pa);
    }
    free(c);
}
