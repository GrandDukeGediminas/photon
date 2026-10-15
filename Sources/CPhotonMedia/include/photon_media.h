#ifndef PHOTON_MEDIA_H
#define PHOTON_MEDIA_H
// photon2's Linux media backend (docs/linux-port.md §3.5): GStreamer behind a small C interface, so Swift never
// touches GLib's variadic or macro API.
//
// Video: a decoder the renderer pulls frames from on its own clock (the Linux counterpart of the AVAssetReader in
// VideoTexture.swift). Frames come out in presentation order with their presentation time in stream time (edit lists
// applied, so the first frame of an MP4 is at 0 like AVFoundation reports it) and are converted to BGRA8 on demand.
//
// Audio: an audio-only player for video wallpapers (the counterpart of VideoAudio.swift's AVPlayer).

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct photon_video photon_video;

/// Opens `path` and decodes its first video frame (preroll). NULL on failure; `error` (may be NULL) receives a message.
photon_video *photon_video_open(const char *path, char *error, size_t error_size);
int photon_video_width(const photon_video *v);
int photon_video_height(const photon_video *v);
/// Duration in seconds as GStreamer reports it, or a value <= 0 when unknown.
double photon_video_duration(const photon_video *v);
/// Flushing, accurate seek to `seconds` (stream time). The next frame is the one shown at that time (the frame whose
/// display interval contains it). 0 on success.
int photon_video_seek(photon_video *v, double seconds);
/// Decodes the next frame in presentation order into the pending slot and stores its presentation time.
/// 1 = frame, 0 = end of stream, -1 = error.
int photon_video_next(photon_video *v, double *pts);
/// Makes the pending frame the shown one (the previous shown slot is reused for the next decode).
void photon_video_show_pending(photon_video *v);
/// Converts the shown frame to BGRA8 (`height` rows of `width * 4` bytes, `dst_stride` apart). Only frames that are
/// actually shown are converted, so skipping frames costs only the decode.
void photon_video_convert_shown(photon_video *v, uint8_t *dst, size_t dst_stride);
void photon_video_close(photon_video *v);

typedef struct photon_audio photon_audio;

/// An audio-only player for `path` (video disabled). The sink is autoaudiosink unless PHOTON_AUDIO_SINK names
/// another element (e.g. fakesink for tests). NULL on failure or when the file has no audio.
photon_audio *photon_audio_open(const char *path);
/// Position in seconds, or a negative value when unknown.
double photon_audio_position(photon_audio *a);
double photon_audio_duration(photon_audio *a);
/// Flushing accurate seek to `seconds`, playing at `rate` afterwards (rate > 0).
int photon_audio_seek(photon_audio *a, double seconds, double rate);
void photon_audio_set_volume(photon_audio *a, double volume);
void photon_audio_set_playing(photon_audio *a, int playing);
/// Handles bus messages (end of stream loops back to 0). Call regularly.
void photon_audio_poll(photon_audio *a);
void photon_audio_close(photon_audio *a);

/// Decodes the whole first audio stream of `path` to interleaved float32 at the stream's own sample rate, mono or stereo
/// (more channels are downmixed to stereo by audioconvert), for OpenAL buffers (sound objects, docs/linux-port.md §3.6).
/// Returns malloc'd samples (release with free()) or NULL.
float *photon_audio_decode(const char *path, int *rate, int *channels, size_t *frames);

#ifdef __cplusplus
}
#endif
#endif
