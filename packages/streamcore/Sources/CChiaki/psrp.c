#include "psrp.h"

#include <chiaki/discoveryservice.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/opusencoder.h>
#include <chiaki/regist.h>
#include <chiaki/remote/holepunch.h>
#include <chiaki/orientation.h>
#include <chiaki/session.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ---------------------------------------------------------------------------------------------
// Homebrew's static libevent is built against the host's (newer) SDK and references pipe2(),
// which older macOS SDKs don't export. Provide it so the static link resolves on any SDK.
// ---------------------------------------------------------------------------------------------
#include <fcntl.h>
int pipe2(int fds[2], int flags);
int pipe2(int fds[2], int flags) {
    if (pipe(fds) != 0) return -1;
    for (int i = 0; i < 2; i++) {
        if ((flags & O_CLOEXEC) && fcntl(fds[i], F_SETFD, FD_CLOEXEC) != 0) goto fail;
        if ((flags & O_NONBLOCK) && fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK) != 0) goto fail;
    }
    return 0;
fail:
    close(fds[0]);
    close(fds[1]);
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Logging / init
// ---------------------------------------------------------------------------------------------

static ChiakiLog g_log;
static PsrpLogCallback g_log_cb;
static void *g_log_user;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void log_forward(ChiakiLogLevel level, const char *msg, void *user) {
    (void)user;
    if (g_log_cb) g_log_cb((int)level, msg, g_log_user);
    else chiaki_log_cb_print(level, msg, NULL);
}

static void lib_init_once(void) { chiaki_lib_init(); }

void psrp_init(PsrpLogCallback cb, void *user, uint32_t level_mask) {
    pthread_once(&g_once, lib_init_once);
    g_log_cb = cb;
    g_log_user = user;
    chiaki_log_init(&g_log, level_mask ? level_mask : (CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR),
                    log_forward, NULL);
}

static void ensure_init(void) {
    if (!g_log.cb) psrp_init(NULL, NULL, 0);
}

static void set_error(char *error, size_t size, const char *fmt, const char *detail) {
    if (error && size) snprintf(error, size, fmt, detail ? detail : "");
}

static void copy_str(char *dst, size_t size, const char *src) {
    if (!size) return;
    snprintf(dst, size, "%s", src ? src : "");
}

// ---------------------------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------------------------

typedef struct {
    pthread_mutex_t mutex;
    PsrpHost *out;
    int max;
    int count;
} DiscoveryCtx;

static void discovery_cb(ChiakiDiscoveryHost *hosts, size_t hosts_count, void *user) {
    DiscoveryCtx *ctx = user;
    pthread_mutex_lock(&ctx->mutex);
    ctx->count = 0;
    for (size_t i = 0; i < hosts_count && ctx->count < ctx->max; i++) {
        ChiakiDiscoveryHost *h = &hosts[i];
        PsrpHost *o = &ctx->out[ctx->count++];
        memset(o, 0, sizeof(*o));
        copy_str(o->address, sizeof(o->address), h->host_addr);
        copy_str(o->name, sizeof(o->name), h->host_name);
        copy_str(o->host_id, sizeof(o->host_id), h->host_id);
        copy_str(o->system_version, sizeof(o->system_version), h->system_version);
        copy_str(o->running_app_name, sizeof(o->running_app_name), h->running_app_name);
        copy_str(o->running_app_id, sizeof(o->running_app_id), h->running_app_titleid);
        o->ps5 = chiaki_discovery_host_is_ps5(h);
        o->state = h->state == CHIAKI_DISCOVERY_HOST_STATE_READY     ? PSRP_HOST_READY
                   : h->state == CHIAKI_DISCOVERY_HOST_STATE_STANDBY ? PSRP_HOST_STANDBY
                                                                     : PSRP_HOST_UNKNOWN;
    }
    pthread_mutex_unlock(&ctx->mutex);
}

/// IPv4 broadcast address of every interface that is up (255.255.255.255 alone often only
/// leaves through one interface on macOS).
static size_t broadcast_addresses(struct sockaddr_storage *out, size_t max) {
    struct ifaddrs *ifs;
    if (getifaddrs(&ifs) != 0) return 0;
    size_t n = 0;
    for (struct ifaddrs *i = ifs; i && n < max; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !(i->ifa_flags & IFF_UP) ||
            !(i->ifa_flags & IFF_BROADCAST) || (i->ifa_flags & IFF_LOOPBACK) || !i->ifa_broadaddr)
            continue;
        memset(&out[n], 0, sizeof(out[n]));
        memcpy(&out[n], i->ifa_broadaddr, sizeof(struct sockaddr_in));
        n++;
    }
    freeifaddrs(ifs);
    return n;
}

bool psrp_wakeup(const char *host, const char regist_key[PSRP_REGIST_KEY_SIZE], bool ps5) {
    ensure_init();
    // The wakeup credential is the regist key (a hex string) parsed as a number.
    char key[PSRP_REGIST_KEY_SIZE + 1] = {0};
    memcpy(key, regist_key, PSRP_REGIST_KEY_SIZE);
    char *end = NULL;
    uint64_t credential = strtoull(key, &end, 16);
    if (end == key) return false;
    bool sent = chiaki_discovery_wakeup(&g_log, NULL, host, credential, ps5) == CHIAKI_ERR_SUCCESS;
    // A PS5 in deeper rest stops answering for its own address (no ARP reply: "No route to host") but
    // still hears broadcasts, so send the packet to every broadcast address too. Only a console that
    // was paired with this credential reacts to it.
    struct sockaddr_storage addrs[16];
    size_t n = broadcast_addresses(addrs, 16);
    for (size_t i = 0; i < n; i++) {
        char text[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &((struct sockaddr_in *)&addrs[i])->sin_addr, text, sizeof(text))) continue;
        if (chiaki_discovery_wakeup(&g_log, NULL, text, credential, ps5) == CHIAKI_ERR_SUCCESS) sent = true;
    }
    return sent;
}

int psrp_psn_list_consoles(const char *oauth_token, PsrpPsnConsole *out, int max, char *error, size_t error_size) {
    ensure_init();
    ChiakiHolepunchDeviceInfo *devices = NULL;
    size_t count = 0;
    ChiakiErrorCode err = chiaki_holepunch_list_devices(oauth_token, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5, &devices, &count, &g_log);
    if (err != CHIAKI_ERR_SUCCESS) {
        copy_str(error, error_size, chiaki_error_string(err));
        return -1;
    }
    int n = 0;
    for (size_t i = 0; i < count && n < max; i++, n++) {
        memset(&out[n], 0, sizeof(out[n]));
        copy_str(out[n].name, sizeof(out[n].name), devices[i].device_name);
        for (int b = 0; b < 32; b++) snprintf(out[n].duid + 2 * b, 3, "%02x", devices[i].device_uid[b]);
        out[n].remote_play = devices[i].remoteplay_enabled;
    }
    chiaki_holepunch_free_device_list(&devices);
    return n;
}

int psrp_discover(const char *host, int timeout_ms, PsrpHost *out, int max) {
    ensure_init();
    DiscoveryCtx ctx = {.out = out, .max = max, .count = 0};
    pthread_mutex_init(&ctx.mutex, NULL);

    struct sockaddr_in in = {0};
    in.sin_family = AF_INET;
    in.sin_addr.s_addr = 0xffffffff;
    struct sockaddr_storage send_addr = {0};
    memcpy(&send_addr, &in, sizeof(in));
    struct sockaddr_storage bcast[16];

    ChiakiDiscoveryServiceOptions options = {0};
    options.hosts_max = 16;
    options.host_drop_pings = 3;
    options.ping_ms = 300;
    options.ping_initial_ms = 0;
    options.send_addr = &send_addr;
    options.send_addr_size = sizeof(struct sockaddr_in);
    options.send_host = (char *)host; // copied by the service
    if (!host) {
        options.broadcast_addrs = bcast;
        options.broadcast_num = broadcast_addresses(bcast, 16);
    }
    options.cb = discovery_cb;
    options.cb_user = &ctx;

    ChiakiDiscoveryService service;
    if (chiaki_discovery_service_init(&service, &options, &g_log) != CHIAKI_ERR_SUCCESS) {
        pthread_mutex_destroy(&ctx.mutex);
        return -1;
    }
    usleep((useconds_t)timeout_ms * 1000);
    chiaki_discovery_service_fini(&service);

    pthread_mutex_lock(&ctx.mutex);
    int count = ctx.count;
    pthread_mutex_unlock(&ctx.mutex);
    pthread_mutex_destroy(&ctx.mutex);
    return count;
}


// ---------------------------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------------------------

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool done;
    bool success;
    ChiakiRegisteredHost host;
} RegistCtx;

static void regist_cb(ChiakiRegistEvent *event, void *user) {
    RegistCtx *ctx = user;
    pthread_mutex_lock(&ctx->mutex);
    ctx->success = event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS;
    if (ctx->success && event->registered_host) ctx->host = *event->registered_host;
    ctx->done = true;
    pthread_cond_signal(&ctx->cond);
    pthread_mutex_unlock(&ctx->mutex);
}

bool psrp_register(const char *host, bool ps5, const uint8_t account_id[PSRP_ACCOUNT_ID_SIZE], uint32_t pin,
                   PsrpRegistration *out, char *error, size_t error_size) {
    ensure_init();
    ChiakiRegistInfo info = {0};
    info.host = host;
    info.target = ps5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
    info.broadcast = false;
    info.psn_online_id = NULL;
    memcpy(info.psn_account_id, account_id, PSRP_ACCOUNT_ID_SIZE);
    info.pin = pin;
    info.console_pin = 0;
    info.holepunch_info = NULL;
    info.rudp = NULL;

    RegistCtx ctx = {0};
    pthread_mutex_init(&ctx.mutex, NULL);
    pthread_cond_init(&ctx.cond, NULL);

    ChiakiRegist regist;
    if (chiaki_regist_start(&regist, &g_log, &info, regist_cb, &ctx) != CHIAKI_ERR_SUCCESS) {
        set_error(error, error_size, "Failed to start registration%s", NULL);
        return false;
    }
    pthread_mutex_lock(&ctx.mutex);
    while (!ctx.done) pthread_cond_wait(&ctx.cond, &ctx.mutex);
    pthread_mutex_unlock(&ctx.mutex);
    chiaki_regist_fini(&regist);
    pthread_cond_destroy(&ctx.cond);
    pthread_mutex_destroy(&ctx.mutex);

    if (!ctx.success) {
        set_error(error, error_size,
                  "Registration failed%s: check the PIN (it expires after a few minutes), the account ID, "
                  "and that the console is on and on the same network",
                  NULL);
        return false;
    }
    memset(out, 0, sizeof(*out));
    memcpy(out->regist_key, ctx.host.rp_regist_key, PSRP_REGIST_KEY_SIZE);
    memcpy(out->rp_key, ctx.host.rp_key, PSRP_RP_KEY_SIZE);
    copy_str(out->nickname, sizeof(out->nickname), ctx.host.server_nickname);
    memcpy(out->mac, ctx.host.server_mac, sizeof(out->mac));
    out->target = (int)ctx.host.target;
    return true;
}

// ---------------------------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------------------------

struct PsrpSession {
    ChiakiSession session;
    ChiakiOpusDecoder opus;
    /// The Mac's microphone to the console: Opus-encoded 10 ms stereo frames (connected on first use).
    ChiakiOpusEncoder mic;
    bool mic_connected;
    PsrpCallbacks cb;
    char host[256];
    ChiakiConnectInfo info;
    /// The chiaki session exists (and was started); before that, controller input etc. are dropped.
    bool started;
    // Internet play: set up on `worker` before the chiaki session exists.
    bool remote;
    char *psn_token;
    uint8_t console_duid[32];
    pthread_t worker;
    pthread_mutex_t lock;
    bool stopping;
    ChiakiHolepunchSession holepunch; // owned here until handed to chiaki_session_init
    /// Orientation from the controller's gyro + accelerometer (Madgwick), as chiaki-ng does it.
    ChiakiOrientationTracker orientation;
    ChiakiAccelNewZero accel_zero;
};

static bool session_video_cb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user) {
    PsrpSession *s = user;
    return s->cb.video ? s->cb.video(s->cb.user, buf, buf_size, frames_lost, frame_recovered) : true;
}

static void session_audio_settings_cb(uint32_t channels, uint32_t rate, void *user) {
    PsrpSession *s = user;
    if (s->cb.audio_format) s->cb.audio_format(s->cb.user, channels, rate);
}

static void session_audio_frame_cb(int16_t *buf, size_t samples_count, void *user) {
    PsrpSession *s = user;
    if (s->cb.audio) s->cb.audio(s->cb.user, buf, samples_count);
}

PsrpQuitKind psrp_quit_kind(int reason) {
    switch ((ChiakiQuitReason)reason) {
    case CHIAKI_QUIT_REASON_STOPPED: return PSRP_QUIT_STOPPED;
    case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE: return PSRP_QUIT_BUSY;
    // Unexplained losses only: REMOTE_DISCONNECTED means the console ended it on purpose (with a reason).
    case CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN:
    case CHIAKI_QUIT_REASON_CTRL_UNKNOWN: return PSRP_QUIT_DROPPED;
    default: return PSRP_QUIT_FINAL;
    }
}

static void session_event_cb(ChiakiEvent *event, void *user) {
    PsrpSession *s = user;
    if (event->type == CHIAKI_EVENT_TRIGGER_EFFECTS) {
        if (s->cb.trigger_effects)
            s->cb.trigger_effects(s->cb.user, event->trigger_effects.type_left, event->trigger_effects.left,
                                  event->trigger_effects.type_right, event->trigger_effects.right);
        return;
    }
    if (!s->cb.event) return;
    switch (event->type) {
    case CHIAKI_EVENT_CONNECTED:
        s->cb.event(s->cb.user, PSRP_EVENT_CONNECTED, 0, 0, NULL);
        break;
    case CHIAKI_EVENT_QUIT: {
        char msg[512];
        snprintf(msg, sizeof(msg), "%s%s%s", chiaki_quit_reason_string(event->quit.reason),
                 event->quit.reason_str ? ": " : "", event->quit.reason_str ? event->quit.reason_str : "");
        s->cb.event(s->cb.user, PSRP_EVENT_QUIT, chiaki_quit_reason_is_error(event->quit.reason) ? 1 : 0,
                    psrp_quit_kind(event->quit.reason), msg);
        break;
    }
    case CHIAKI_EVENT_KEYBOARD_OPEN:
    case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
    case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE:
        s->cb.event(s->cb.user, PSRP_EVENT_KEYBOARD,
                    event->type == CHIAKI_EVENT_KEYBOARD_OPEN ? PSRP_KEYBOARD_OPEN
                    : event->type == CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE ? PSRP_KEYBOARD_CHANGE : PSRP_KEYBOARD_CLOSE,
                    0, event->keyboard.text_str ? event->keyboard.text_str : "");
        break;
    case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
        s->cb.event(s->cb.user, PSRP_EVENT_LOGIN_PIN_REQUEST, event->login_pin_request.pin_incorrect ? 1 : 0, 0, NULL);
        break;
    case CHIAKI_EVENT_RUMBLE:
        s->cb.event(s->cb.user, PSRP_EVENT_RUMBLE, event->rumble.left, event->rumble.right, NULL);
        break;
    case CHIAKI_EVENT_HOLEPUNCH:
        s->cb.event(s->cb.user, PSRP_EVENT_REMOTE_PROGRESS,
                    event->data_holepunch.finished ? PSRP_REMOTE_CONNECTED : PSRP_REMOTE_DATA, 0, NULL);
        break;
    case CHIAKI_EVENT_NICKNAME_RECEIVED:
        s->cb.event(s->cb.user, PSRP_EVENT_NICKNAME, 0, 0, event->server_nickname);
        break;
    default:
        break;
    }
}

/// Creates and starts the chiaki session from `s->info`. Callers hold `s->lock` (remote) or own `s` alone.
static ChiakiErrorCode start_chiaki(PsrpSession *s) {
    ChiakiErrorCode err = chiaki_session_init(&s->session, &s->info, &g_log);
    if (err != CHIAKI_ERR_SUCCESS) return err;
    chiaki_opus_decoder_init(&s->opus, &g_log);
    chiaki_opus_decoder_set_cb(&s->opus, session_audio_settings_cb, session_audio_frame_cb, s);
    ChiakiAudioSink sink;
    chiaki_opus_decoder_get_sink(&s->opus, &sink);
    chiaki_session_set_audio_sink(&s->session, &sink);
    chiaki_opus_encoder_init(&s->mic, &g_log);
    ChiakiAudioHeader mic_header;
    chiaki_audio_header_set(&mic_header, 2, 16, PSRP_MIC_SAMPLE_RATE, PSRP_MIC_FRAME_SAMPLES);
    chiaki_opus_encoder_header(&mic_header, &s->mic, &s->session);
    chiaki_session_set_video_sample_cb(&s->session, session_video_cb, s);
    chiaki_session_set_event_cb(&s->session, session_event_cb, s);
    err = chiaki_session_start(&s->session);
    if (err != CHIAKI_ERR_SUCCESS) {
        chiaki_session_fini(&s->session);
        chiaki_opus_decoder_fini(&s->opus);
        chiaki_opus_encoder_fini(&s->mic);
        return err;
    }
    __atomic_store_n(&s->started, true, __ATOMIC_RELEASE);
    return CHIAKI_ERR_SUCCESS;
}

static bool started(PsrpSession *s) { return s && __atomic_load_n(&s->started, __ATOMIC_ACQUIRE); }

const char *psrp_remote_error_message(int err) {
    switch ((ChiakiErrorCode)err) {
    case CHIAKI_ERR_HOST_DOWN:
        return "PSN couldn't reach your PS5. Check that it's on, or in rest mode with \"Stay connected to the "
               "internet\" turned on.";
    case CHIAKI_ERR_HOST_UNREACH:
        return "Your PS5 answered, but the connection couldn't get through this network. Try another network.";
    default:
        return "Connecting over the internet failed.";
    }
}

bool psrp_parse_duid(const char *hex, uint8_t out[32]) {
    if (!hex || strlen(hex) != 64) return false;
    for (int i = 0; i < 32; i++) {
        unsigned int byte;
        char pair[3] = {hex[2 * i], hex[2 * i + 1], 0};
        char *end = NULL;
        byte = (unsigned int)strtoul(pair, &end, 16);
        if (end != pair + 2) return false;
        out[i] = (uint8_t)byte;
    }
    return true;
}

static void emit_quit(PsrpSession *s, ChiakiErrorCode err) {
    if (!s->cb.event) return;
    if (err == CHIAKI_ERR_CANCELED) {
        s->cb.event(s->cb.user, PSRP_EVENT_QUIT, 0, PSRP_QUIT_STOPPED, "Stopped");
        return;
    }
    char msg[512];
    snprintf(msg, sizeof(msg), "%s (%s)", psrp_remote_error_message(err), chiaki_error_string(err));
    s->cb.event(s->cb.user, PSRP_EVENT_QUIT, 1, PSRP_QUIT_FINAL, msg);
}

/// Internet play setup: PSN session, reach the console, punch the control hole, then start chiaki
/// (which registers over PSN and opens the data connection itself). Each step can block up to ~30 s;
/// psrp_session_stop cancels them.
static void *remote_worker(void *arg) {
    PsrpSession *s = arg;
    if (s->cb.event) s->cb.event(s->cb.user, PSRP_EVENT_REMOTE_PROGRESS, PSRP_REMOTE_LINKING, 0, NULL);
    ChiakiHolepunchSession hp = chiaki_holepunch_session_init(s->psn_token, &g_log);
    if (!hp) {
        emit_quit(s, CHIAKI_ERR_UNKNOWN);
        return NULL;
    }
    pthread_mutex_lock(&s->lock);
    bool stop = s->stopping;
    if (!stop) s->holepunch = hp;
    pthread_mutex_unlock(&s->lock);
    ChiakiErrorCode err = stop ? CHIAKI_ERR_CANCELED : CHIAKI_ERR_SUCCESS;
    if (err == CHIAKI_ERR_SUCCESS) chiaki_holepunch_upnp_discover(hp); // best effort
    if (err == CHIAKI_ERR_SUCCESS) err = chiaki_holepunch_session_create(hp);
    if (err == CHIAKI_ERR_SUCCESS) err = holepunch_session_create_offer(hp);
    if (err == CHIAKI_ERR_SUCCESS)
        err = chiaki_holepunch_session_start(hp, s->console_duid, CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5);
    if (err == CHIAKI_ERR_SUCCESS) err = chiaki_holepunch_session_punch_hole(hp, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);

    pthread_mutex_lock(&s->lock);
    if (err == CHIAKI_ERR_SUCCESS && s->stopping) err = CHIAKI_ERR_CANCELED;
    s->holepunch = NULL;
    if (err == CHIAKI_ERR_SUCCESS) {
        s->info.holepunch_session = hp; // chiaki owns it from here (and finalizes it, even on failure)
        hp = NULL;
        err = start_chiaki(s);
    }
    pthread_mutex_unlock(&s->lock);
    if (hp) chiaki_holepunch_session_fini(hp);
    if (err != CHIAKI_ERR_SUCCESS) emit_quit(s, err);
    return NULL;
}

PsrpSession *psrp_session_start(const PsrpSessionConfig *config, const PsrpCallbacks *callbacks, char *error,
                                size_t error_size) {
    ensure_init();
    PsrpSession *s = calloc(1, sizeof(PsrpSession));
    if (!s) return NULL;
    chiaki_orientation_tracker_init(&s->orientation);
    chiaki_accel_new_zero_set_inactive(&s->accel_zero, true);
    pthread_mutex_init(&s->lock, NULL);
    s->cb = *callbacks;
    s->remote = config->psn_token != NULL;
    copy_str(s->host, sizeof(s->host), s->remote ? "" : config->host);

    ChiakiConnectInfo *info = &s->info;
    info->ps5 = config->ps5;
    info->host = s->host;
    memcpy(info->regist_key, config->regist_key, sizeof(info->regist_key));
    memcpy(info->morning, config->rp_key, sizeof(info->morning));
    memcpy(info->psn_account_id, config->account_id, sizeof(info->psn_account_id));

    ChiakiVideoResolutionPreset res = config->height >= 1080  ? CHIAKI_VIDEO_RESOLUTION_PRESET_1080p
                                      : config->height >= 720 ? CHIAKI_VIDEO_RESOLUTION_PRESET_720p
                                      : config->height >= 540 ? CHIAKI_VIDEO_RESOLUTION_PRESET_540p
                                                              : CHIAKI_VIDEO_RESOLUTION_PRESET_360p;
    chiaki_connect_video_profile_preset(&info->video_profile, res,
                                        config->fps >= 60 ? CHIAKI_VIDEO_FPS_PRESET_60 : CHIAKI_VIDEO_FPS_PRESET_30);
    if (config->bitrate > 0) info->video_profile.bitrate = (unsigned int)config->bitrate;
    info->video_profile.codec = config->ps5 ? (ChiakiCodec)config->codec : CHIAKI_CODEC_H264;
    info->video_profile_auto_downgrade = config->auto_downgrade;
    info->enable_keyboard = true; // the console sends KEYBOARD_* events; the host types for it
    info->enable_dualsense = config->ps5;
    info->audio_video_disabled = 0;
    info->auto_regist = false;
    info->holepunch_session = NULL;
    info->rudp_sock = NULL;
    info->packet_loss_max = 0.05;
    info->enable_idr_on_fec_failure = true;

    if (s->remote) {
        if (!config->ps5 || !psrp_parse_duid(config->psn_duid, s->console_duid)) {
            copy_str(error, error_size, "Internet play needs a PS5 and its PSN device ID");
            pthread_mutex_destroy(&s->lock);
            free(s);
            return NULL;
        }
        s->psn_token = strdup(config->psn_token);
        if (!s->psn_token || pthread_create(&s->worker, NULL, remote_worker, s) != 0) {
            copy_str(error, error_size, "Couldn't start connecting over the internet");
            free(s->psn_token);
            pthread_mutex_destroy(&s->lock);
            free(s);
            return NULL;
        }
        return s;
    }

    ChiakiErrorCode err = start_chiaki(s);
    if (err != CHIAKI_ERR_SUCCESS) {
        set_error(error, error_size, "Session start failed: %s", chiaki_error_string(err));
        pthread_mutex_destroy(&s->lock);
        free(s);
        return NULL;
    }
    return s;
}

void psrp_session_set_controller_state(PsrpSession *s, const PsrpControllerState *c) {
    if (!started(s) || !c) return;
    ChiakiControllerState state;
    chiaki_controller_state_set_idle(&state);
    state.buttons = c->buttons;
    state.l2_state = c->l2;
    state.r2_state = c->r2;
    state.left_x = c->left_x;
    state.left_y = c->left_y;
    state.right_x = c->right_x;
    state.right_y = c->right_y;
    for (int i = 0; i < PSRP_TOUCHES_MAX && i < CHIAKI_CONTROLLER_TOUCHES_MAX; i++) {
        state.touches[i].id = c->touches[i].id;
        state.touches[i].x = c->touches[i].x;
        state.touches[i].y = c->touches[i].y;
    }
    if (c->motion) {
        chiaki_orientation_tracker_update(&s->orientation, c->gyro_x, c->gyro_y, c->gyro_z, c->accel_x, c->accel_y,
                                          c->accel_z, &s->accel_zero, true, c->motion_timestamp_us);
        chiaki_orientation_tracker_apply_to_controller_state(&s->orientation, &state);
    }
    chiaki_session_set_controller_state(&s->session, &state);
}

uint64_t psrp_session_rtt_us(PsrpSession *s) {
    return s ? s->session.rtt_us : 0;
}

void psrp_session_set_login_pin(PsrpSession *s, const char *pin) {
    if (!started(s) || !pin) return;
    chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void psrp_session_keyboard_set_text(PsrpSession *s, const char *text) {
    if (started(s) && text) chiaki_session_keyboard_set_text(&s->session, text);
}

void psrp_session_keyboard_done(PsrpSession *s, bool accept) {
    if (!started(s)) return;
    if (accept) chiaki_session_keyboard_accept(&s->session);
    else chiaki_session_keyboard_reject(&s->session);
}

void psrp_session_request_idr(PsrpSession *s) {
    if (started(s)) chiaki_session_request_idr(&s->session);
}

void psrp_session_set_mic(PsrpSession *s, bool on) {
    if (!started(s)) return;
    if (on && !s->mic_connected) {
        chiaki_session_connect_microphone(&s->session);
        s->mic_connected = true;
    }
    if (s->mic_connected) chiaki_session_toggle_microphone(&s->session, !on);
}

void psrp_session_mic_frame(PsrpSession *s, const int16_t *pcm) {
    if (!started(s) || !s->mic_connected || !pcm) return;
    chiaki_opus_encoder_frame((int16_t *)pcm, &s->mic);
}

void psrp_session_goto_bed(PsrpSession *s) {
    if (started(s)) chiaki_session_goto_bed(&s->session);
}

void psrp_session_stop(PsrpSession *s) {
    if (!s) return;
    if (s->remote) {
        // Cancel whatever setup step is blocking, then wait for the worker to give up.
        pthread_mutex_lock(&s->lock);
        s->stopping = true;
        if (s->holepunch) chiaki_holepunch_main_thread_cancel(s->holepunch, true);
        pthread_mutex_unlock(&s->lock);
        pthread_join(s->worker, NULL);
        free(s->psn_token);
    }
    if (started(s)) {
        chiaki_session_stop(&s->session);
        chiaki_session_join(&s->session);
        chiaki_session_fini(&s->session);
        chiaki_opus_decoder_fini(&s->opus);
        chiaki_opus_encoder_fini(&s->mic);
    }
    pthread_mutex_destroy(&s->lock);
    free(s);
}
