// GStreamer media backend for photon2 on Linux (photon_media.h, docs/linux-port.md §3.5).
#include "photon_media.h"

#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static int init_ok = 0;

static void init_gst(void) {
    GError *err = NULL;
    init_ok = gst_init_check(NULL, NULL, &err) ? 1 : 0;
    if (err) g_error_free(err);
}

static int ensure_gst(void) {
    pthread_once(&init_once, init_gst);
    return init_ok;
}

static void set_error(char *error, size_t size, const char *fmt, const char *detail) {
    if (error && size > 0) snprintf(error, size, fmt, detail ? detail : "");
}

/// The first error message on the bus, if any (non-blocking).
static int bus_error(GstElement *pipeline, char *error, size_t size) {
    GstBus *bus = gst_element_get_bus(pipeline);
    int found = 0;
    GstMessage *msg;
    while (!found && (msg = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR)) != NULL) {
        GError *err = NULL;
        gst_message_parse_error(msg, &err, NULL);
        set_error(error, size, "%s", err ? err->message : "unknown GStreamer error");
        if (err) g_error_free(err);
        gst_message_unref(msg);
        found = 1;
    }
    gst_object_unref(bus);
    return found;
}

// MARK: - Video

/// One decoded frame: 8-bit 4:2:0 planes copied out of the GStreamer buffer (the decoder's pool stays free).
typedef struct {
    uint8_t *planes[3];
    int strides[3];
    size_t capacity;
    uint8_t *storage;
} yuv_frame;

struct photon_video {
    GstElement *pipeline;
    GstElement *sink;
    int width, height;
    double duration;
    int eos;
    /// Y'CbCr → R'G'B' for this stream (from the caps colorimetry; see photon_video_open).
    float ky, krv, kgu, kgv, kbu;
    int yoffset, full_range;
    yuv_frame slots[2];
    int pending; // index of the slot photon_video_next fills; the other is the shown frame
};

/// decodebin exposes one pad per decoded stream; only the first raw video stream is linked (audio stays unlinked, which
/// qtdemux/matroskademux tolerate as long as one stream is linked).
static void on_pad_added(GstElement *decoder, GstPad *pad, gpointer data) {
    (void)decoder;
    GstElement *convert = data;
    GstPad *sinkpad = gst_element_get_static_pad(convert, "sink");
    if (!gst_pad_is_linked(sinkpad)) {
        GstCaps *caps = gst_pad_get_current_caps(pad);
        if (!caps) caps = gst_pad_query_caps(pad, NULL);
        const char *name = caps && gst_caps_get_size(caps) > 0 ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : "";
        if (g_str_has_prefix(name, "video/")) gst_pad_link(pad, sinkpad);
        if (caps) gst_caps_unref(caps);
    }
    gst_object_unref(sinkpad);
}

/// The stream's Y'CbCr matrix and range from its caps colorimetry. GStreamer fills an untagged stream's matrix from
/// its size (BT.601 up to 576 lines, BT.709 above); PHOTON_VIDEO_MATRIX=601|709 overrides for experiments.
static void set_matrix(photon_video *v, const GstVideoColorimetry *c) {
    float kr = 0.2126f, kb = 0.0722f;
    GstVideoColorMatrix m = c->matrix;
    const char *force = getenv("PHOTON_VIDEO_MATRIX");
    if (force && strcmp(force, "601") == 0) m = GST_VIDEO_COLOR_MATRIX_BT601;
    if (force && strcmp(force, "709") == 0) m = GST_VIDEO_COLOR_MATRIX_BT709;
    switch (m) {
    case GST_VIDEO_COLOR_MATRIX_BT601: kr = 0.299f; kb = 0.114f; break;
    case GST_VIDEO_COLOR_MATRIX_FCC: kr = 0.30f; kb = 0.11f; break;
    case GST_VIDEO_COLOR_MATRIX_SMPTE240M: kr = 0.212f; kb = 0.087f; break;
    case GST_VIDEO_COLOR_MATRIX_BT2020: kr = 0.2627f; kb = 0.0593f; break;
    default: break;
    }
    float kg = 1.0f - kr - kb;
    v->full_range = c->range == GST_VIDEO_COLOR_RANGE_0_255;
    v->yoffset = v->full_range ? 0 : 16;
    v->ky = v->full_range ? 1.0f : 255.0f / 219.0f;
    v->krv = 2.0f * (1.0f - kr);
    v->kbu = 2.0f * (1.0f - kb);
    v->kgu = 2.0f * kb * (1.0f - kb) / kg;
    v->kgv = 2.0f * kr * (1.0f - kr) / kg;
}

photon_video *photon_video_open(const char *path, char *error, size_t error_size) {
    if (!ensure_gst()) {
        set_error(error, error_size, "%s", "gst_init failed");
        return NULL;
    }
    GstElement *pipeline = gst_pipeline_new("photon-video");
    GstElement *src = gst_element_factory_make("filesrc", NULL);
    GstElement *dec = gst_element_factory_make("decodebin", NULL);
    GstElement *conv = gst_element_factory_make("videoconvert", NULL);
    GstElement *filter = gst_element_factory_make("capsfilter", NULL);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!pipeline || !src || !dec || !conv || !filter || !sink) {
        set_error(error, error_size, "%s", "missing GStreamer elements (filesrc, decodebin, videoconvert, capsfilter, appsink)");
        if (pipeline) gst_object_unref(pipeline);
        GstElement *loose[] = {src, dec, conv, filter, sink};
        for (int i = 0; i < 5; i++) if (loose[i]) gst_object_unref(loose[i]);
        return NULL;
    }
    g_object_set(src, "location", path, NULL);
    // 8-bit 4:2:0 (what H.264/HEVC/VP9 wallpapers decode to; videoconvert passes it through untouched and converts
    // anything else). The conversion to BGRA is done here rather than by videoconvert, whose fixed-point matrices are
    // off by up to 4 levels from the standard ones VideoToolbox (macOS) uses.
    GstCaps *caps = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "I420", NULL);
    g_object_set(filter, "caps", caps, NULL);
    gst_caps_unref(caps);
    // Pull model: no clock sync, a short queue, every frame kept (the renderer decides which one to show).
    g_object_set(sink, "sync", FALSE, "max-buffers", 2, "drop", FALSE, "enable-last-sample", FALSE, NULL);
    gst_bin_add_many(GST_BIN(pipeline), src, dec, conv, filter, sink, NULL);
    if (!gst_element_link(src, dec) || !gst_element_link_many(conv, filter, sink, NULL)) {
        set_error(error, error_size, "%s", "cannot link the decode pipeline");
        gst_object_unref(pipeline);
        return NULL;
    }
    g_signal_connect(dec, "pad-added", G_CALLBACK(on_pad_added), conv);

    gst_element_set_state(pipeline, GST_STATE_PAUSED);
    GstStateChangeReturn r = gst_element_get_state(pipeline, NULL, NULL, 20 * GST_SECOND);
    if (r == GST_STATE_CHANGE_FAILURE || r == GST_STATE_CHANGE_ASYNC) {
        if (!bus_error(pipeline, error, error_size)) set_error(error, error_size, "%s", "preroll failed or timed out");
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return NULL;
    }
    GstSample *preroll = gst_app_sink_try_pull_preroll(GST_APP_SINK(sink), 5 * GST_SECOND);
    GstVideoInfo info;
    if (!preroll || !gst_video_info_from_caps(&info, gst_sample_get_caps(preroll))) {
        if (preroll) gst_sample_unref(preroll);
        if (!bus_error(pipeline, error, error_size)) set_error(error, error_size, "%s", "no video stream");
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return NULL;
    }
    gst_sample_unref(preroll);

    photon_video *v = calloc(1, sizeof *v);
    v->pipeline = pipeline;
    v->sink = sink;
    v->width = GST_VIDEO_INFO_WIDTH(&info);
    v->height = GST_VIDEO_INFO_HEIGHT(&info);
    set_matrix(v, &info.colorimetry);
    gint64 dur = -1;
    v->duration = gst_element_query_duration(pipeline, GST_FORMAT_TIME, &dur) && dur > 0 ? (double)dur / GST_SECOND : -1;
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    return v;
}

int photon_video_width(const photon_video *v) { return v->width; }
int photon_video_height(const photon_video *v) { return v->height; }
double photon_video_duration(const photon_video *v) { return v->duration; }

int photon_video_seek(photon_video *v, double seconds) {
    gint64 t = seconds > 0 ? (gint64)(seconds * GST_SECOND + 0.5) : 0;
    v->eos = 0;
    gboolean ok = gst_element_seek(v->pipeline, 1.0, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE,
                                   GST_SEEK_TYPE_SET, t, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE);
    return ok ? 0 : -1;
}

static int copy_frame(yuv_frame *f, GstVideoFrame *frame, int width, int height) {
    int cw = (width + 1) / 2, ch = (height + 1) / 2;
    size_t need = (size_t)width * height + 2 * (size_t)cw * ch;
    if (f->capacity < need) {
        free(f->storage);
        f->storage = malloc(need);
        if (!f->storage) {
            f->capacity = 0;
            return 0;
        }
        f->capacity = need;
    }
    f->planes[0] = f->storage;
    f->planes[1] = f->storage + (size_t)width * height;
    f->planes[2] = f->planes[1] + (size_t)cw * ch;
    f->strides[0] = width;
    f->strides[1] = f->strides[2] = cw;
    int widths[3] = {width, cw, cw}, heights[3] = {height, ch, ch};
    for (int p = 0; p < 3; p++) {
        const uint8_t *src = GST_VIDEO_FRAME_COMP_DATA(frame, p);
        int stride = GST_VIDEO_FRAME_COMP_STRIDE(frame, p);
        int w = GST_VIDEO_FRAME_COMP_WIDTH(frame, p), h = GST_VIDEO_FRAME_COMP_HEIGHT(frame, p);
        if (w > widths[p]) w = widths[p];
        if (h > heights[p]) h = heights[p];
        for (int y = 0; y < h; y++) memcpy(f->planes[p] + (size_t)y * f->strides[p], src + (size_t)y * stride, (size_t)w);
    }
    return 1;
}

int photon_video_next(photon_video *v, double *pts) {
    if (v->eos) return 0;
    for (;;) {
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(v->sink), 30 * GST_SECOND);
        if (!sample) {
            if (gst_app_sink_is_eos(GST_APP_SINK(v->sink))) {
                v->eos = 1;
                return 0;
            }
            return -1;
        }
        GstBuffer *buf = gst_sample_get_buffer(sample);
        GstVideoInfo info;
        GstVideoFrame frame;
        if (!buf || !gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
            !gst_video_frame_map(&frame, &info, buf, GST_MAP_READ)) {
            gst_sample_unref(sample);
            continue;
        }
        int ok = copy_frame(&v->slots[v->pending], &frame, v->width, v->height);
        gst_video_frame_unmap(&frame);
        GstClockTime t = GST_BUFFER_PTS(buf);
        const GstSegment *segment = gst_sample_get_segment(sample);
        if (GST_CLOCK_TIME_IS_VALID(t) && segment && segment->format == GST_FORMAT_TIME) {
            guint64 st = gst_segment_to_stream_time(segment, GST_FORMAT_TIME, t);
            if (GST_CLOCK_TIME_IS_VALID(st)) t = st;
        }
        *pts = GST_CLOCK_TIME_IS_VALID(t) ? (double)t / GST_SECOND : 0;
        gst_sample_unref(sample);
        return ok ? 1 : -1;
    }
}

void photon_video_show_pending(photon_video *v) { v->pending ^= 1; }

static inline uint8_t clamp8(float x) {
    // Round half up, as the conversion's float result is never negative zero-sensitive here.
    int i = (int)(x + 0.5f);
    return i < 0 ? 0 : i > 255 ? 255 : (uint8_t)i;
}

void photon_video_convert_shown(photon_video *v, uint8_t *dst, size_t dst_stride) {
    const yuv_frame *f = &v->slots[v->pending ^ 1];
    if (!f->storage) return;
    int w = v->width, h = v->height, cw = (w + 1) / 2, ch = (h + 1) / 2;
    const float cscale = v->full_range ? 1.0f : 255.0f / 224.0f;
    const float ky = v->ky, krv = v->krv * cscale, kgu = v->kgu * cscale, kgv = v->kgv * cscale, kbu = v->kbu * cscale;
    const float yoff = (float)v->yoffset;
    // Chroma upsampled bilinearly with H.264's default siting (type 0, as MPEG-2): horizontally co-sited with the
    // even luma column, vertically centred between two luma rows. Measured best against VideoToolbox's BGRA output.
    float *cu = malloc(sizeof(float) * (size_t)cw * 2);
    if (!cu) return;
    float *cv = cu + cw;
    for (int y = 0; y < h; y++) {
        int r = y >> 1;
        int r2 = (y & 1) ? (r + 1 < ch ? r + 1 : ch - 1) : (r > 0 ? r - 1 : 0);
        const uint8_t *u0 = f->planes[1] + (size_t)r * f->strides[1], *u1 = f->planes[1] + (size_t)r2 * f->strides[1];
        const uint8_t *v0 = f->planes[2] + (size_t)r * f->strides[2], *v1 = f->planes[2] + (size_t)r2 * f->strides[2];
        for (int x = 0; x < cw; x++) {
            cu[x] = (3 * u0[x] + u1[x]) * 0.25f - 128.0f;
            cv[x] = (3 * v0[x] + v1[x]) * 0.25f - 128.0f;
        }
        const uint8_t *yr = f->planes[0] + (size_t)y * f->strides[0];
        uint8_t *out = dst + (size_t)y * dst_stride;
        for (int x = 0; x < w; x++) {
            int c = x >> 1;
            float u, vv;
            if (x & 1) {
                int c2 = c + 1 < cw ? c + 1 : cw - 1;
                u = 0.5f * (cu[c] + cu[c2]);
                vv = 0.5f * (cv[c] + cv[c2]);
            } else {
                u = cu[c];
                vv = cv[c];
            }
            float yy = ((float)yr[x] - yoff) * ky;
            out[4 * x + 0] = clamp8(yy + kbu * u);
            out[4 * x + 1] = clamp8(yy - kgu * u - kgv * vv);
            out[4 * x + 2] = clamp8(yy + krv * vv);
            out[4 * x + 3] = 255;
        }
    }
    free(cu);
}

void photon_video_close(photon_video *v) {
    if (!v) return;
    free(v->slots[0].storage);
    free(v->slots[1].storage);
    gst_element_set_state(v->pipeline, GST_STATE_NULL);
    gst_object_unref(v->pipeline);
    free(v);
}

// MARK: - Audio

struct photon_audio {
    GstElement *playbin;
    int eos;
};

photon_audio *photon_audio_open(const char *path) {
    if (!ensure_gst()) return NULL;
    GstElement *playbin = gst_element_factory_make("playbin", NULL);
    if (!playbin) return NULL;
    gchar *uri = gst_filename_to_uri(path, NULL);
    if (!uri) {
        gst_object_unref(playbin);
        return NULL;
    }
    // GST_PLAY_FLAG_AUDIO (0x2) only: the picture comes from the video texture.
    g_object_set(playbin, "uri", uri, "flags", 0x2, NULL);
    g_free(uri);
    const char *sinkName = getenv("PHOTON_AUDIO_SINK");
    if (sinkName && *sinkName) {
        GstElement *sink = gst_element_factory_make(sinkName, NULL);
        if (sink) {
            if (g_object_class_find_property(G_OBJECT_GET_CLASS(sink), "sync")) g_object_set(sink, "sync", TRUE, NULL);
            g_object_set(playbin, "audio-sink", sink, NULL);
        }
    }
    gst_element_set_state(playbin, GST_STATE_PAUSED);
    GstStateChangeReturn r = gst_element_get_state(playbin, NULL, NULL, 10 * GST_SECOND);
    gint naudio = 0;
    g_object_get(playbin, "n-audio", &naudio, NULL);
    if (r == GST_STATE_CHANGE_FAILURE || naudio <= 0) {
        gst_element_set_state(playbin, GST_STATE_NULL);
        gst_object_unref(playbin);
        return NULL;
    }
    photon_audio *a = calloc(1, sizeof *a);
    a->playbin = playbin;
    return a;
}

double photon_audio_position(photon_audio *a) {
    gint64 pos = -1;
    if (a->eos) return photon_audio_duration(a);
    return gst_element_query_position(a->playbin, GST_FORMAT_TIME, &pos) && pos >= 0 ? (double)pos / GST_SECOND : -1;
}

double photon_audio_duration(photon_audio *a) {
    gint64 dur = -1;
    return gst_element_query_duration(a->playbin, GST_FORMAT_TIME, &dur) && dur > 0 ? (double)dur / GST_SECOND : -1;
}

int photon_audio_seek(photon_audio *a, double seconds, double rate) {
    a->eos = 0;
    gint64 t = seconds > 0 ? (gint64)(seconds * GST_SECOND + 0.5) : 0;
    return gst_element_seek(a->playbin, rate > 0 ? rate : 1.0, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE,
                            GST_SEEK_TYPE_SET, t, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE) ? 0 : -1;
}

void photon_audio_set_volume(photon_audio *a, double volume) {
    g_object_set(a->playbin, "volume", volume < 0 ? 0.0 : volume, NULL);
}

void photon_audio_set_playing(photon_audio *a, int playing) {
    gst_element_set_state(a->playbin, playing ? GST_STATE_PLAYING : GST_STATE_PAUSED);
}

void photon_audio_poll(photon_audio *a) {
    GstBus *bus = gst_element_get_bus(a->playbin);
    GstMessage *msg;
    while ((msg = gst_bus_pop_filtered(bus, GST_MESSAGE_EOS | GST_MESSAGE_ERROR)) != NULL) {
        if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_EOS) a->eos = 1;
        gst_message_unref(msg);
    }
    gst_object_unref(bus);
}

void photon_audio_close(photon_audio *a) {
    if (!a) return;
    gst_element_set_state(a->playbin, GST_STATE_NULL);
    gst_object_unref(a->playbin);
    free(a);
}

// MARK: - Whole-file decode (sound objects)

/// decodebin → audioconvert (to F32LE interleaved, 1 or 2 channels; the rate is left alone) → appsink. Only the first
/// audio pad is linked.
static void on_audio_pad(GstElement *decoder, GstPad *pad, gpointer data) {
    (void)decoder;
    GstElement *convert = data;
    GstPad *sinkpad = gst_element_get_static_pad(convert, "sink");
    if (!gst_pad_is_linked(sinkpad)) {
        GstCaps *caps = gst_pad_get_current_caps(pad);
        if (!caps) caps = gst_pad_query_caps(pad, NULL);
        const char *name = caps && gst_caps_get_size(caps) > 0 ? gst_structure_get_name(gst_caps_get_structure(caps, 0)) : "";
        if (g_str_has_prefix(name, "audio/")) gst_pad_link(pad, sinkpad);
        if (caps) gst_caps_unref(caps);
    }
    gst_object_unref(sinkpad);
}

float *photon_audio_decode(const char *path, int *rate, int *channels, size_t *frames) {
    if (!ensure_gst()) return NULL;
    GstElement *pipeline = gst_pipeline_new(NULL);
    GstElement *src = gst_element_factory_make("filesrc", NULL);
    GstElement *dec = gst_element_factory_make("decodebin", NULL);
    GstElement *conv = gst_element_factory_make("audioconvert", NULL);
    GstElement *sink = gst_element_factory_make("appsink", NULL);
    if (!pipeline || !src || !dec || !conv || !sink) {
        if (pipeline) gst_object_unref(pipeline);
        return NULL;
    }
    g_object_set(src, "location", path, NULL);
    GstCaps *caps = gst_caps_from_string("audio/x-raw,format=F32LE,layout=interleaved,channels=[1,2]");
    g_object_set(sink, "caps", caps, "sync", FALSE, NULL);
    gst_caps_unref(caps);
    gst_bin_add_many(GST_BIN(pipeline), src, dec, conv, sink, NULL);
    if (!gst_element_link(src, dec) || !gst_element_link(conv, sink)) {
        gst_object_unref(pipeline);
        return NULL;
    }
    g_signal_connect(dec, "pad-added", G_CALLBACK(on_audio_pad), conv);
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    float *out = NULL;
    size_t count = 0, capacity = 0;
    int r = 0, ch = 0;
    for (;;) {
        GstSample *s = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 10 * GST_SECOND);
        if (!s) break;
        if (!r) {
            GstStructure *st = gst_caps_get_structure(gst_sample_get_caps(s), 0);
            gst_structure_get_int(st, "rate", &r);
            gst_structure_get_int(st, "channels", &ch);
        }
        GstBuffer *b = gst_sample_get_buffer(s);
        GstMapInfo map;
        if (b && gst_buffer_map(b, &map, GST_MAP_READ)) {
            size_t n = map.size / sizeof(float);
            if (count + n > capacity) {
                capacity = (count + n) * 2;
                float *grown = realloc(out, capacity * sizeof(float));
                if (!grown) { gst_buffer_unmap(b, &map); gst_sample_unref(s); free(out); out = NULL; count = 0; break; }
                out = grown;
            }
            memcpy(out + count, map.data, n * sizeof(float));
            count += n;
            gst_buffer_unmap(b, &map);
        }
        gst_sample_unref(s);
    }
    int failed = bus_error(pipeline, NULL, 0);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    if (failed || !out || r <= 0 || ch <= 0 || count < (size_t)ch) { free(out); return NULL; }
    *rate = r;
    *channels = ch;
    *frames = count / (size_t)ch;
    return out;
}
