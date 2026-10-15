// Audio streams of other applications for the "another application plays audio" playback rule and the
// "playingaudio" application rules (photon_system.h, docs/re/09 §1.3/§1.5, docs/linux-port.md §5). The engine watches
// WASAPI audio sessions (AudioEventHandler 0x140138b80); here the sink inputs of PulseAudio or pipewire-pulse: a stream
// that is not corked is playing. Queried synchronously on a context kept across calls.
#include "photon_system.h"

#include <pulse/pulseaudio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static pa_mainloop *ml;
static pa_context *ctx;
static double next_attempt;

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void drop(void) {
    if (ctx) { pa_context_disconnect(ctx); pa_context_unref(ctx); ctx = NULL; }
    if (ml) { pa_mainloop_free(ml); ml = NULL; }
}

/// Iterates the loop until `done` or `ms` pass.
static int run_until(volatile int *done, int ms) {
    double end = now_s() + ms / 1000.0;
    while (!*done && now_s() < end) {
        if (pa_mainloop_iterate(ml, 0, NULL) < 0) return 0;
        if (!*done) {
            struct timespec t = { 0, 2 * 1000 * 1000 };
            nanosleep(&t, NULL);
        }
    }
    return *done;
}

static int connect_ctx(void) {
    if (ctx && pa_context_get_state(ctx) == PA_CONTEXT_READY) return 1;
    if (ctx) drop();
    if (now_s() < next_attempt) return 0;
    next_attempt = now_s() + 5;
    ml = pa_mainloop_new();
    pa_proplist *pl = pa_proplist_new();
    pa_proplist_sets(pl, PA_PROP_APPLICATION_NAME, "photon2 audio-session probe");
    ctx = pa_context_new_with_proplist(pa_mainloop_get_api(ml), "photon2", pl);
    pa_proplist_free(pl);
    if (!ctx || pa_context_connect(ctx, NULL, PA_CONTEXT_NOAUTOSPAWN, NULL) < 0) { drop(); return 0; }
    double end = now_s() + 2;
    while (now_s() < end) {
        pa_context_state_t st = pa_context_get_state(ctx);
        if (st == PA_CONTEXT_READY) return 1;
        if (!PA_CONTEXT_IS_GOOD(st)) break;
        pa_mainloop_iterate(ml, 0, NULL);
        struct timespec t = { 0, 2 * 1000 * 1000 };
        nanosleep(&t, NULL);
    }
    drop();
    return 0;
}

typedef struct {
    photon_audio_stream *out;
    int max, n;
    volatile int done;
} list_ctx;

static void on_sink_input(pa_context *c, const pa_sink_input_info *i, int eol, void *data) {
    list_ctx *l = data;
    if (eol) { l->done = 1; return; }
    if (!i || l->n >= l->max) return;
    photon_audio_stream *s = &l->out[l->n++];
    memset(s, 0, sizeof *s);
    s->index = i->index;
    s->corked = i->corked;
    s->muted = i->mute;
    const char *pid = pa_proplist_gets(i->proplist, PA_PROP_APPLICATION_PROCESS_ID);
    s->pid = pid ? atoi(pid) : 0;
    const char *bin = pa_proplist_gets(i->proplist, PA_PROP_APPLICATION_PROCESS_BINARY);
    const char *name = pa_proplist_gets(i->proplist, PA_PROP_APPLICATION_NAME);
    snprintf(s->binary, sizeof s->binary, "%s", bin ? bin : "");
    snprintf(s->application, sizeof s->application, "%s", name ? name : (i->name ? i->name : ""));
}

int photon_audio_streams(photon_audio_stream *out, int max) {
    if (!connect_ctx()) return -1;
    list_ctx l = { out, max, 0, 0 };
    pa_operation *op = pa_context_get_sink_input_info_list(ctx, on_sink_input, &l);
    if (!op) { drop(); return -1; }
    int ok = run_until(&l.done, 1000);
    pa_operation_unref(op);
    if (!ok) { drop(); return -1; }
    return l.n;
}
