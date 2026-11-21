// psrp: a small, opaque C API over libchiaki (third_party/chiaki-ng) for PS4/PS5 Remote Play
// on the local network. Swift (StreamCore) only sees this header, never chiaki's.
#ifndef PSRP_H
#define PSRP_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PSRP_ACCOUNT_ID_SIZE 8
#define PSRP_REGIST_KEY_SIZE 16
#define PSRP_RP_KEY_SIZE 16

typedef enum { PSRP_LOG_ERROR = 1, PSRP_LOG_WARNING = 2, PSRP_LOG_INFO = 4, PSRP_LOG_VERBOSE = 8, PSRP_LOG_DEBUG = 16 } PsrpLogLevel;
typedef void (*PsrpLogCallback)(int level, const char *message, void *user);

/// Initializes libchiaki once. `level_mask` is an OR of PsrpLogLevel. Safe to call repeatedly
/// (later calls only update the callback and mask).
void psrp_init(PsrpLogCallback cb, void *user, uint32_t level_mask);

/// The QoS class (a `qos_class_t`) libchiaki's thread `name` (a `ChiakiThreadName`) runs at: user-interactive
/// for those on the path of every frame and button press. Applied as each thread starts.
unsigned int psrp_thread_qos(int name);

// ---------------------------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------------------------

typedef enum { PSRP_HOST_UNKNOWN = 0, PSRP_HOST_READY = 1, PSRP_HOST_STANDBY = 2 } PsrpHostState;

typedef struct {
    char address[64];
    char name[64];
    char host_id[32];
    char system_version[16];
    char running_app_name[128];
    char running_app_id[32];
    bool ps5;
    int state; // PsrpHostState
} PsrpHost;

/// Blocks for `timeout_ms`, pinging either `host` (unicast) or every IPv4 broadcast address
/// (host == NULL). Returns the number of consoles written to `out` (<= max), or -1 on error.
int psrp_discover(const char *host, int timeout_ms, PsrpHost *out, int max);

/// Sends a wakeup packet (console must be in rest mode with "stay connected" enabled).
bool psrp_wakeup(const char *host, const char regist_key[PSRP_REGIST_KEY_SIZE], bool ps5);

// ---------------------------------------------------------------------------------------------
// Consoles on the PSN account (for playing over the internet; PS5 only)
// ---------------------------------------------------------------------------------------------

typedef struct {
    char name[32];
    char duid[65];      // the console's PSN device ID, 32 bytes as lowercase hex
    bool remote_play;   // Remote Play enabled on the console
} PsrpPsnConsole;

/// Blocking (up to ~5 s). Lists the PS5s on the PSN account behind `oauth_token`. Returns the number
/// written to `out` (<= max), or -1 with a message in `error`.
int psrp_psn_list_consoles(const char *oauth_token, PsrpPsnConsole *out, int max, char *error, size_t error_size);

// ---------------------------------------------------------------------------------------------
// Registration (pairing with the 8-digit PIN from Settings > System > Remote Play > Pair Device)
// ---------------------------------------------------------------------------------------------

typedef struct {
    char regist_key[PSRP_REGIST_KEY_SIZE]; // "rp_regist_key", \0-padded hex string
    uint8_t rp_key[PSRP_RP_KEY_SIZE];      // "morning"
    char nickname[32];
    uint8_t mac[6];
    int target; // ChiakiTarget
} PsrpRegistration;

/// Blocking. Returns true on success; on failure writes a message into `error` saying why and what to do.
bool psrp_register(const char *host, bool ps5, const uint8_t account_id[PSRP_ACCOUNT_ID_SIZE], uint32_t pin,
                   PsrpRegistration *out, char *error, size_t error_size);
/// The user-facing message for a failed registration: libchiaki's error, the console's RP-Application-Reason
/// (0 if it gave none) and whether the console had answered before it failed, from the regist event.
void psrp_regist_error_message(int chiaki_error, uint32_t application_reason, bool answered, bool ps5, char *out,
                               size_t size);

// ---------------------------------------------------------------------------------------------
// Streaming session
// ---------------------------------------------------------------------------------------------

typedef enum {
    PSRP_EVENT_CONNECTED = 1,
    PSRP_EVENT_QUIT = 2,              // message = reason; a = 1 if it was an error; b = PsrpQuitKind
    PSRP_EVENT_LOGIN_PIN_REQUEST = 3, // a = 1 if the previous PIN was wrong
    PSRP_EVENT_RUMBLE = 4,            // a = left (low freq), b = right (high freq)
    PSRP_EVENT_NICKNAME = 5,          // message = console nickname
    PSRP_EVENT_REMOTE_PROGRESS = 6,   // a = PsrpRemoteStage (connecting over the internet)
    PSRP_EVENT_KEYBOARD = 7,          // a = PsrpKeyboardChange; message = the field's text (open/change)
    PSRP_EVENT_HAPTIC_RUMBLE = 8,     // a = left, b = right, from the DualSense haptics stream. The console
                                      // stops sending it when an effect ends (no silence follows), so it is
                                      // repeated every 50 ms while it lasts and expires when it isn't.
    PSRP_EVENT_LIGHT = 9,             // a = the DualSense light bar colour, 0xRRGGBB
    PSRP_EVENT_PLAYER_INDEX = 10,     // a = the pad's player number as the console counts it (0 = player 1)
} PsrpEventType;

/// The console's text keyboard: a field was focused (open, with its text), the console changed the text,
/// or it closed the keyboard itself.
typedef enum { PSRP_KEYBOARD_OPEN = 0, PSRP_KEYBOARD_CHANGE = 1, PSRP_KEYBOARD_CLOSE = 2 } PsrpKeyboardChange;

/// Steps of connecting over the internet, as they start.
typedef enum {
    PSRP_REMOTE_LINKING = 1,       // PSN session + reaching the console (up to ~30 s per step)
    PSRP_REMOTE_DATA = 2,          // linked; opening the data connection
    PSRP_REMOTE_CONNECTED = 3,     // data connection open
    PSRP_REMOTE_REGISTERING = 4,   // pairing through PSN (`register_only`): linked; registering with the console
} PsrpRemoteStage;

/// Why a session ended, as far as what to do next is concerned.
typedef enum {
    PSRP_QUIT_FINAL = 0,   // console asleep, disconnected on purpose, incompatible…: don't retry
    PSRP_QUIT_BUSY = 1,    // Remote Play still in use on the console (~9 s after a session ends): retry soon
    PSRP_QUIT_DROPPED = 2, // the connection was lost mid-stream without a reason: worth reconnecting
    PSRP_QUIT_STOPPED = 3, // stopped by this client (e.g. replaced by a new session)
} PsrpQuitKind;

/// The user-facing message for a libchiaki error while connecting over the internet.
const char *psrp_remote_error_message(int chiaki_error);
/// Parses a 64-hex-char PSN device ID into 32 bytes.
bool psrp_parse_duid(const char *hex, uint8_t out[32]);

/// Classifies a libchiaki `ChiakiQuitReason` value.
PsrpQuitKind psrp_quit_kind(int reason);

typedef enum { PSRP_CODEC_H264 = 0, PSRP_CODEC_H265 = 1, PSRP_CODEC_H265_HDR = 2 } PsrpCodec;

/// The DualSense haptics stream's sample rate (interleaved stereo 16-bit PCM, one channel per motor).
#define PSRP_HAPTICS_SAMPLE_RATE 3000

typedef struct {
    void *user;
    /// One complete Annex-B access unit. Return false if it couldn't be decoded (requests an IDR).
    bool (*video)(void *user, const uint8_t *data, size_t size, int32_t frames_lost, bool recovered);
    void (*audio_format)(void *user, uint32_t channels, uint32_t rate);
    /// Interleaved signed 16-bit PCM; `frames` samples per channel.
    void (*audio)(void *user, const int16_t *pcm, size_t frames);
    void (*event)(void *user, int type, int a, int b, const char *message);
    /// DualSense adaptive trigger effects, in the controller's own format: a mode byte and 10 parameter
    /// bytes per trigger.
    void (*trigger_effects)(void *user, uint8_t type_left, const uint8_t *left, uint8_t type_right, const uint8_t *right);
    /// The DualSense haptics stream as it arrives: `frames` interleaved stereo samples at
    /// PSRP_HAPTICS_SAMPLE_RATE. Return true if it was played on a pad: then no PSRP_EVENT_HAPTIC_RUMBLE is made
    /// from it. Optional.
    bool (*haptics)(void *user, const int16_t *pcm, size_t frames);
    /// Pairing through PSN (`register_only`): the console registered this Mac, with the same keys a PIN
    /// pairing gives. PSRP_EVENT_QUIT (PSRP_QUIT_STOPPED) follows. Optional.
    void (*registered)(void *user, const PsrpRegistration *registration);
} PsrpCallbacks;

typedef struct {
    const char *host;
    bool ps5;
    char regist_key[PSRP_REGIST_KEY_SIZE];
    uint8_t rp_key[PSRP_RP_KEY_SIZE];
    uint8_t account_id[PSRP_ACCOUNT_ID_SIZE];
    int height;  // 360, 540, 720 or 1080
    int fps;     // 30 or 60
    int codec;   // PsrpCodec (PS4 is always H.264)
    int bitrate; // kbps, 0 = preset default
    bool auto_downgrade; // let the console lower the resolution when the network can't keep up
    /// Set both to connect over the internet (PS5): a valid PSN OAuth token and the console's PSN device
    /// ID (64 hex chars). `host` is then ignored. Setup runs in the background; progress arrives as
    /// PSRP_EVENT_REMOTE_PROGRESS, failures as PSRP_EVENT_QUIT.
    const char *psn_token;
    const char *psn_duid;
    /// Pairing through PSN, no PIN (PS5): with `psn_token`, `psn_duid` and `account_id` set (no keys needed,
    /// they don't exist yet), the session only registers this Mac with the console over PSN, as every internet
    /// session does first, then stops. The keys arrive through `callbacks.registered`; a quit without them
    /// is a failure.
    bool register_only;
} PsrpSessionConfig;

typedef struct PsrpSession PsrpSession;

/// Starts connecting in the background; progress arrives through `callbacks.event`.
PsrpSession *psrp_session_start(const PsrpSessionConfig *config, const PsrpCallbacks *callbacks,
                                char *error, size_t error_size);

/// DualSense/DualShock button bits (same values as chiaki's ChiakiControllerButton).
typedef enum {
    PSRP_BTN_CROSS = 1 << 0, PSRP_BTN_CIRCLE = 1 << 1, PSRP_BTN_SQUARE = 1 << 2, PSRP_BTN_TRIANGLE = 1 << 3,
    PSRP_BTN_DPAD_LEFT = 1 << 4, PSRP_BTN_DPAD_RIGHT = 1 << 5, PSRP_BTN_DPAD_UP = 1 << 6, PSRP_BTN_DPAD_DOWN = 1 << 7,
    PSRP_BTN_L1 = 1 << 8, PSRP_BTN_R1 = 1 << 9, PSRP_BTN_L3 = 1 << 10, PSRP_BTN_R3 = 1 << 11,
    PSRP_BTN_OPTIONS = 1 << 12, PSRP_BTN_SHARE = 1 << 13, PSRP_BTN_TOUCHPAD = 1 << 14, PSRP_BTN_PS = 1 << 15,
} PsrpButton;

#define PSRP_TOUCHES_MAX 2
#define PSRP_TOUCHPAD_WIDTH 1920
#define PSRP_TOUCHPAD_HEIGHT 1079

/// A finger on the touchpad. `id` stays the same while the finger is down (0–127); -1 = no finger.
typedef struct {
    int8_t id;
    uint16_t x, y; // 0…PSRP_TOUCHPAD_WIDTH, 0…PSRP_TOUCHPAD_HEIGHT
} PsrpTouch;

typedef struct {
    uint32_t buttons; // PsrpButton bits
    uint8_t l2, r2;
    int16_t left_x, left_y, right_x, right_y;
    PsrpTouch touches[PSRP_TOUCHES_MAX];
    /// Motion sensors, when `motion` is set: gyro in rad/s, accelerometer in g (gravity included), and the
    /// reading's time in µs (any monotonic clock, wrapping). The shim derives the orientation.
    bool motion;
    float gyro_x, gyro_y, gyro_z;
    float accel_x, accel_y, accel_z;
    uint32_t motion_timestamp_us;
} PsrpControllerState;

void psrp_session_set_controller_state(PsrpSession *session, const PsrpControllerState *state);
void psrp_session_set_login_pin(PsrpSession *session, const char *pin);
/// Round trip to the console in microseconds, measured while connecting (0 until then).
uint64_t psrp_session_rtt_us(PsrpSession *session);
/// The bitrate the console's encoder aims for now (bit/s, from its connection quality reports; 0 before one).
uint32_t psrp_session_target_bitrate(PsrpSession *session);
/// How long a missing video packet is waited for before it's skipped (measured from the link by libchiaki's
/// Takion), and what it learned from: holes that filled while waiting, packets that came after their hole was
/// skipped, skipped holes nothing came for, and holes skipped because the reorder queue was full.
typedef struct {
    uint32_t wait_us; // 0 before the stream connects
    uint32_t holes_filled;
    uint32_t late_packets;
    uint32_t holes_lost;
    uint32_t queue_full_skips;
} PsrpReorderStats;
/// Safe from any thread; all zero without a session.
void psrp_session_reorder_stats(PsrpSession *session, PsrpReorderStats *out);
/// One frame of the DualSense haptics stream (`frames` interleaved stereo samples) as rumble strengths.
void psrp_haptics_to_rumble(const int16_t *samples, size_t frames, uint8_t *left, uint8_t *right);

/// The Mac's microphone to the console (voice chat): turn it on/off (the first "on" connects it), and
/// send each 10 ms of audio as PSRP_MIC_FRAME_SAMPLES interleaved stereo 16-bit samples at 48 kHz.
#define PSRP_MIC_SAMPLE_RATE 48000
#define PSRP_MIC_FRAME_SAMPLES 480
void psrp_session_set_mic(PsrpSession *session, bool on);
void psrp_session_mic_frame(PsrpSession *session, const int16_t *pcm);
/// Typing into the console's focused text field: replace its text, then accept (Return) or reject (Esc).
void psrp_session_keyboard_set_text(PsrpSession *session, const char *text);
void psrp_session_keyboard_done(PsrpSession *session, bool accept);
void psrp_session_request_idr(PsrpSession *session);
/// Puts the console into rest mode.
void psrp_session_goto_bed(PsrpSession *session);
/// Stops, joins and frees the session. Callbacks are not invoked after this returns.
void psrp_session_stop(PsrpSession *session);

#ifdef __cplusplus
}
#endif

#endif
