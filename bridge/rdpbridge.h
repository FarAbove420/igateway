//
//  rdpbridge.h
//
//  A small C surface over libfreerdp-client, shaped for a Cocoa app to drive.
//
//  The app owns the NSWindow and FreeRDP only produces pixels, so resizing,
//  fullscreen, input and the clipboard are the app's to handle, the way a Mac
//  app does them.
//
//  Behaviour was checked against the FreeRDP 3 source, the SDL3 and Mac
//  clients in particular, and the MS-RDPEDISP and MS-RDPBCGR specs.
//

#ifndef RDPBRIDGE_H
#define RDPBRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPSession RDPSession;

typedef enum {
    RDPSessionStateIdle = 0,
    RDPSessionStateConnecting,
    RDPSessionStateConnected,
    RDPSessionStateDisconnected,
    RDPSessionStateFailed
} RDPSessionState;

typedef struct {
    int32_t x, y, width, height;
} RDPRect;

typedef struct {
    uint32_t id;
    const char *name;   /* NULL for predefined formats such as CF_UNICODETEXT */
} RDPClipFormat;

/// Cursor ids passed to `cursorSet`.
#define RDP_CURSOR_DEFAULT 0u
#define RDP_CURSOR_HIDDEN  0xFFFFFFFFu

/// Every callback runs on the session thread unless noted.
/// A certificate FreeRDP could not verify by itself: not signed by an
/// authority the Mac trusts, and not stored from an earlier connection.
typedef struct {
    const char *host;
    uint16_t port;
    const char *commonName;
    const char *subject;
    const char *issuer;
    /// The certificate in PEM when `isPEM`, otherwise FreeRDP's fingerprint.
    const char *fingerprint;
    bool isPEM;
    bool gateway;
    /// A different certificate than the one stored for this host.
    bool changed;
    /// The name on the certificate does not match the host.
    bool mismatch;
    /// The stored certificate, when `changed`.
    const char *oldSubject;
    const char *oldIssuer;
    const char *oldFingerprint;
    bool oldIsPEM;
} RDPCertificate;

#define RDP_CERT_REFUSE 0u
#define RDP_CERT_TRUST 1u
#define RDP_CERT_TRUST_ONCE 2u

typedef struct {
    void *user;

    /// The desktop changed. `dirty` is the changed area; `full` is true when
    /// the whole buffer must be taken (first frame, resize). `pixels` is only
    /// valid for the duration of the call.
    void (*frame)(void *user, const uint8_t *pixels, int width, int height,
                  int stride, RDPRect dirty, bool full);

    void (*state)(void *user, RDPSessionState state, const char *detail);

    /// Remote cursor shapes, BGRA with straight alpha.
    void (*cursorNew)(void *user, uint32_t id, const uint8_t *bgra,
                      int width, int height, int hotX, int hotY);
    void (*cursorFree)(void *user, uint32_t id);
    void (*cursorSet)(void *user, uint32_t id);

    /// The clipboard channel is up. Announce the local clipboard now.
    void (*clipReady)(void *user);
    /// Something was copied on the remote side.
    void (*clipServerFormats)(void *user, const RDPClipFormat *formats, int count);
    /// Answer to rdp_session_clip_request.
    void (*clipData)(void *user, uint32_t formatId, const uint8_t *data, size_t length, bool ok);
    /// The remote side is pasting. Return malloc'd data, which the bridge frees.
    bool (*clipProvide)(void *user, uint32_t formatId, uint8_t **data, size_t *length);
    /// The remote side is reading a file we announced. `sizeOnly` asks for the
    /// 64-bit size, otherwise `count` bytes from `offset`. Malloc'd, bridge frees.
    bool (*clipFileProvide)(void *user, uint32_t listIndex, bool sizeOnly,
                            uint64_t offset, uint32_t count,
                            uint8_t **data, size_t *length);
    /// Answer to rdp_session_clip_request_file.
    void (*clipFileData)(void *user, uint32_t streamId, const uint8_t *data,
                         size_t length, bool ok);

    /// Asks the user about a certificate. Called on the session thread, which
    /// waits for the answer: RDP_CERT_TRUST stores it, RDP_CERT_TRUST_ONCE
    /// accepts it for this connection, RDP_CERT_REFUSE ends the connection.
    uint32_t (*certificate)(void *user, const RDPCertificate *certificate);
} RDPCallbacks;

typedef struct {
    const char *username;
    const char *domain;
    const char *password;
    /// The RD Gateway can want a different account than the host behind it.
    const char *gatewayUsername;
    const char *gatewayDomain;
    const char *gatewayPassword;
    /// 100 for normal, 200 for a Retina-sharp desktop. MS-RDPEDISP accepts
    /// 100 to 500.
    uint32_t scaleFactor;
} RDPCredentials;

/// `argv` is a FreeRDP command line WITHOUT passwords, parsed with FreeRDP's
/// own parser so every flag behaves exactly as in sdl-freerdp. Passwords go in
/// through `credentials` and straight into the settings, so they never pass
/// through a command line at all.
RDPSession *rdp_session_create(const char *const *argv, int argc,
                               const RDPCredentials *credentials,
                               const RDPCallbacks *callbacks);

/// Connects and runs the event loop on its own thread. Returns immediately.
bool rdp_session_start(RDPSession *session);
void rdp_session_stop(RDPSession *session);
void rdp_session_free(RDPSession *session);

const char *rdp_session_error(RDPSession *session);

/// Asks the server for a new desktop size in pixels. Rate limited and sent from
/// the session thread once the server has said it supports display control.
/// Width is rounded down to even and both are clamped to 200..8192, as
/// MS-RDPEDISP 2.2.2.2.1 requires.
void rdp_session_request_size(RDPSession *session, int width, int height, uint32_t scaleFactor);

/// Whether the server accepted display control, i.e. whether resizing the
/// window will resize the remote desktop rather than just scale it.
bool rdp_session_can_resize(RDPSession *session);

/// Input. Coordinates are remote desktop pixels.
void rdp_session_send_mouse(RDPSession *session, uint16_t flags, uint16_t x, uint16_t y);
void rdp_session_send_wheel(RDPSession *session, bool horizontal, int units);
/// The pointer flags for one wheel step of -256..255 units.
uint16_t rdp_wheel_flags(bool horizontal, int step);
/// Mouse buttons 4 and 5 (back and forward on most mice).
void rdp_session_send_xbutton(RDPSession *session, int button, bool down, uint16_t x, uint16_t y);
void rdp_session_send_key(RDPSession *session, uint16_t scancode, bool down, bool repeat);

/// How far FreeRDP's connection sequence got, coarsely.
typedef enum {
    RDPStageTransport = 0,   ///< network, TLS, gateway tunnel
    RDPStageLogin,           ///< NLA (or Azure AD) sign-in to the server
    RDPStageSetup,           ///< MCS and security settings
    RDPStageLicensing,
    RDPStageActivation,      ///< capabilities and finalization
    RDPStageActive
} RDPStage;

/// Where a failed connection got to, gathered from FreeRDP's state and its own
/// log while it ran, so the app can say which step failed.
typedef struct {
    /// freerdp_get_last_error.
    uint32_t errorCode;
    /// CONNECTION_STATE when it ended, -1 if unknown, and as a stage and name.
    int32_t connectionState;
    RDPStage stage;
    char stateName[64];
    char errorName[96];
    /// Furthest gateway tunnel step reached (FreeRDP's TSG states): -1 none,
    /// 0 started, 1 signed in, 2 allowed by policy, 3 server reached, 4 ready.
    int32_t gatewayProgress;
    /// The gateway's own reason code (E_PROXY_*), 0 if none.
    uint32_t gatewayReason;
    /// An authentication error was logged, and how far the gateway was then.
    bool authError;
    int32_t authErrorProgress;
    /// The last few error lines from FreeRDP's log, for "Copy Details".
    char details[1200];
} RDPDiagnosis;

/// Routes FreeRDP's log through the bridge: written to <directory>/freerdp.log
/// as before, and read along for the diagnosis. Once, before anything else.
void rdp_log_init(const char *directory);
/// The diagnosis saved when the session failed, or the current one.
bool rdp_session_diagnosis(RDPSession *session, RDPDiagnosis *out);
/// Only what the log showed, without a session. For tests.
void rdp_log_diagnosis(RDPDiagnosis *out);
void rdp_log_reset(void);

/// Sets Windows' lock keys to the given states (MS-RDPBCGR synchronize event),
/// so Caps Lock in Windows matches the Mac's.
void rdp_session_send_locks(RDPSession *session, bool capsLock, bool numLock);
/// Returns false if the server does not take Unicode input.
bool rdp_session_send_unicode(RDPSession *session, uint16_t code, bool down);

/// Clipboard, client to server. Safe from any thread.
bool rdp_session_clip_announce(RDPSession *session, const RDPClipFormat *formats, int count);
bool rdp_session_clip_request(RDPSession *session, uint32_t formatId);
bool rdp_session_clip_request_file(RDPSession *session, uint32_t streamId, uint32_t listIndex,
                                   bool sizeOnly, uint64_t offset, uint32_t count);
/// The server's clipboard capability flags, for example whether it takes files.
uint32_t rdp_session_clip_server_flags(RDPSession *session);

/// Copies a rectangle and forces alpha to opaque. FreeRDP's alpha byte is not
/// reliable, and Core Animation would otherwise blend it.
void rdp_copy_rect_opaque(uint8_t *dst, size_t dstStride,
                          const uint8_t *src, size_t srcStride,
                          int x, int y, int width, int height);

/// macOS virtual key code to RDP scancode (extended keys carry 0x100), using
/// WinPR's Apple table. `iso` swaps the two keys macOS reports differently on
/// ISO keyboards, as MacFreeRDP does.
uint16_t rdp_scancode_for_mac_keycode(uint16_t keyCode, bool iso);

/// Whether the Mac's keyboard is ISO, via KBGetLayoutType(LMGetKbdType()).
bool rdp_mac_keyboard_is_iso(void);

/// The linked FreeRDP's version, for the log.
const char *rdp_freerdp_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RDPBRIDGE_H */
