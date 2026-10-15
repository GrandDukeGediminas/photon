#ifndef PHOTON_SYSTEM_H
#define PHOTON_SYSTEM_H
// photon2's Linux system services (docs/linux-port.md §3.6, §5.1) behind a small C interface, so Swift never touches
// PipeWire's SPA pod builders, PulseAudio or GLib's variadic API:
//
// - Spectrum capture: the system output mix as float32 packets, the counterpart of the engine's WASAPI loopback
//   capture (docs/re/06 §5.1) and of the macOS process tap. PipeWire: a pw_stream with stream.capture.sink = true,
//   which links to the default sink's monitor ports. PulseAudio (or pipewire-pulse) fallback: a pa_simple record
//   stream on `@DEFAULT_MONITOR@`.
// - Media sessions: MPRIS (org.mpris.MediaPlayer2.*) on the session bus, the counterpart of the WinRT
//   GlobalSystemMediaTransportControls session winrtutil64.exe reads and of macOS MediaRemote.
// - Playback-rule signals: UPower OnBattery, logind PrepareForSleep and the session's Lock/Unlock/LockedHint,
//   org.freedesktop.ScreenSaver / org.gnome.ScreenSaver ActiveChanged (docs/re/09 §1.4 inputs).

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Spectrum capture

typedef struct photon_capture photon_capture;
/// Called on the capture thread with one packet of interleaved float32 frames.
typedef void (*photon_capture_cb)(void *context, const float *samples, uint32_t frames, uint32_t channels);

/// Starts capture. `backend`: "pipewire", "pulse" or NULL/"" (PipeWire first, then PulseAudio). NULL when neither
/// backend could be started; `error` (may be NULL) then says why.
photon_capture *photon_capture_open(const char *backend, photon_capture_cb cb, void *context, char *error, size_t error_size);
/// "PipeWire" or "PulseAudio".
const char *photon_capture_backend(const photon_capture *c);
int photon_capture_rate(const photon_capture *c);
int photon_capture_channels(const photon_capture *c);
void photon_capture_close(photon_capture *c);

// MARK: - MPRIS

typedef struct {
    int found;            // a player is on the bus
    char *bus_name;       // org.mpris.MediaPlayer2.<name>
    char *identity;       // org.mpris.MediaPlayer2 Identity ("" when absent)
    char *desktop_entry;  // DesktopEntry ("" when absent)
    char *status;         // PlaybackStatus: Playing / Paused / Stopped
    char *title, *artist, *album, *album_artist, *genres, *art_url;  // lists joined with ", "
    int64_t length_us;    // mpris:length, 0 when absent
    int64_t position_us;  // Position, 0 when absent
    double rate;          // Rate, 1 when absent
} photon_mpris_info;

/// One synchronous poll of the session bus (timeouts 500 ms): the player to show is the first Playing one in name
/// order, else the first Paused one, else the first. Returns 0 when the session bus is unreachable, 1 otherwise
/// (`out->found` says whether a player exists). Free the strings with photon_mpris_info_free.
int photon_mpris_poll(photon_mpris_info *out);
void photon_mpris_info_free(photon_mpris_info *info);

// MARK: - Playback-rule signals

typedef struct {
    int system_bus;       // the system bus answered
    int session_bus;      // the session bus answered
    int upower;           // UPower answered (on_battery is meaningful)
    int on_battery;       // UPower OnBattery
    int logind;           // logind answered
    int preparing_sleep;  // between PrepareForSleep(true) and PrepareForSleep(false)
    int locked;           // the session is locked (Lock/Unlock signals, LockedHint)
    int screensaver;      // a ScreenSaver ActiveChanged(true) without a later (false)
    uint32_t sleep_events, lock_events, screensaver_events, battery_events;
} photon_system_state;

/// Starts the watcher thread (idempotent): subscribes to the signals and reads the initial values.
void photon_system_watch_start(void);
void photon_system_state_get(photon_system_state *out);

// MARK: - Audio streams of other applications

typedef struct {
    uint32_t index;        // sink input index
    int pid;               // application.process.id (0 when the stream does not say)
    int corked;            // the stream is paused (not playing)
    int muted;
    char binary[128];      // application.process.binary
    char application[128]; // application.name (or the stream name)
} photon_audio_stream;

/// The sink inputs (playback streams) of the PulseAudio server or pipewire-pulse, up to `max`: the counterpart of the
/// engine's WASAPI audio sessions for the "another application plays audio" rule. -1 when no server answers (retried
/// at most every 5 s).
int photon_audio_streams(photon_audio_stream *out, int max);

// MARK: - GNOME Shell extension (photon2@photon2.github.io)

typedef struct {
    int started;          // the watcher thread finished its setup
    int bus;              // the session bus answered
    int present;          // io.github.photon2.Shell is on the bus
    uint32_t state_serial;// increments with every new state (GetState answer or StateChanged)
    int pointer_known;    // a PointerChanged arrived
    double x, y;          // the cursor in global logical (stage) coordinates
    int over_desktop;     // the cursor is over the desktop background
    int pressed;          // the left button is held after a press on the desktop
    uint32_t presses;     // desktop presses seen so far
} photon_gnome_shell_info;

/// Starts the watcher thread (idempotent): follows the extension's name on the session bus, its StateChanged and
/// PointerChanged signals.
void photon_gnome_shell_watch_start(void);
void photon_gnome_shell_get(photon_gnome_shell_info *out);
/// The last state JSON (malloc'd; "" while the extension is absent). `serial` receives the state serial.
char *photon_gnome_shell_state_json(uint32_t *serial);
/// GetState, synchronously: 1 when the extension answered within `timeout_ms` (its state is stored as the last one).
int photon_gnome_shell_ping(int timeout_ms);

#ifdef __cplusplus
}
#endif
#endif
