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
// Registration (pairing with the 8-digit PIN from Settings > System > Remote Play > Pair Device)
// ---------------------------------------------------------------------------------------------

typedef struct {
    char regist_key[PSRP_REGIST_KEY_SIZE]; // "rp_regist_key", \0-padded hex string
    uint8_t rp_key[PSRP_RP_KEY_SIZE];      // "morning"
    char nickname[32];
    uint8_t mac[6];
    int target; // ChiakiTarget
} PsrpRegistration;

/// Blocking. Returns true on success; on failure writes a message into `error`.
bool psrp_register(const char *host, bool ps5, const uint8_t account_id[PSRP_ACCOUNT_ID_SIZE], uint32_t pin,
                   PsrpRegistration *out, char *error, size_t error_size);

// ---------------------------------------------------------------------------------------------
// Streaming session
// ---------------------------------------------------------------------------------------------

typedef enum {
    PSRP_EVENT_CONNECTED = 1,
    PSRP_EVENT_QUIT = 2,              // message = reason; a = 1 if it was an error; b = PsrpQuitKind
    PSRP_EVENT_LOGIN_PIN_REQUEST = 3, // a = 1 if the previous PIN was wrong
    PSRP_EVENT_RUMBLE = 4,            // a = left (low freq), b = right (high freq)
    PSRP_EVENT_NICKNAME = 5,          // message = console nickname
} PsrpEventType;

/// Why a session ended, as far as what to do next is concerned.
typedef enum {
    PSRP_QUIT_FINAL = 0,   // console asleep, disconnected on purpose, incompatible…: don't retry
    PSRP_QUIT_BUSY = 1,    // Remote Play still in use on the console (~9 s after a session ends): retry soon
    PSRP_QUIT_DROPPED = 2, // the connection was lost mid-stream without a reason: worth reconnecting
    PSRP_QUIT_STOPPED = 3, // stopped by this client (e.g. replaced by a new session)
} PsrpQuitKind;

/// Classifies a libchiaki `ChiakiQuitReason` value.
PsrpQuitKind psrp_quit_kind(int reason);

typedef enum { PSRP_CODEC_H264 = 0, PSRP_CODEC_H265 = 1, PSRP_CODEC_H265_HDR = 2 } PsrpCodec;

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

void psrp_session_set_controller(PsrpSession *session, uint32_t buttons, uint8_t l2, uint8_t r2,
                                 int16_t left_x, int16_t left_y, int16_t right_x, int16_t right_y);
void psrp_session_set_login_pin(PsrpSession *session, const char *pin);
void psrp_session_request_idr(PsrpSession *session);
/// Puts the console into rest mode.
void psrp_session_goto_bed(PsrpSession *session);
/// Stops, joins and frees the session. Callbacks are not invoked after this returns.
void psrp_session_stop(PsrpSession *session);

#ifdef __cplusplus
}
#endif

#endif
