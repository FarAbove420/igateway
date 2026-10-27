//
//  rdpbridge.c
//
//  See rdpbridge.h for why this exists. Comments point at the FreeRDP 3
//  source a decision was checked against.
//

#include "rdpbridge.h"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/constants.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cmdline.h>

#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/sysinfo.h>
#include <winpr/thread.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------- */
/* Types                                                                  */
/* ---------------------------------------------------------------------- */

/* freerdp_client_OnChannelConnectedEventHandler casts the context to
   rdpClientContext (client/common/client.c), so that must come first. */
typedef struct {
    rdpClientContext common;
    RDPSession *session;
} BridgeContext;

typedef struct {
    rdpPointer pointer;
    uint32_t id;
} BridgePointer;

#define FORMAT_QUEUE_SIZE 64
#define RESIZE_MIN_INTERVAL_MS 500   /* the SDL client uses the same delay */
#define FRAME_MIN_INTERVAL_MS 15

struct RDPSession {
    rdpContext *context;
    HANDLE thread;
    volatile bool stopping;
    RDPCallbacks cb;
    char *error;

    pthread_mutex_t lock;
    /* The graphics pipeline runs on FreeRDP's dynamic channel thread: it
       resizes and paints the desktop there, while the session thread copies
       it out. Held around all three, as the SDL client does (_critical). */
    pthread_mutex_t gdiLock;

    /* Frames. Dirty area accumulated between pushes. */
    bool dirty;
    bool fullDirty;
    int32_t dirtyLeft, dirtyTop, dirtyRight, dirtyBottom;
    uint64_t lastFrameMs;

    /* Cursors */
    uint32_t nextCursorId;

    /* Display control */
    DispClientContext *disp;
    bool dispReady;
    int requestedWidth, requestedHeight;
    uint32_t requestedScale;
    int sentWidth, sentHeight;
    uint32_t sentScale;
    uint64_t lastResizeMs;

    /* Clipboard */
    CliprdrClientContext *cliprdr;
    uint32_t serverClipFlags;
    bool clipListSent;
    /* FormatDataResponse carries no format id (MS-RDPECLIP 2.2.5.2), so the
       requested ids are kept in send order and matched to responses. */
    uint32_t formatQueue[FORMAT_QUEUE_SIZE];
    int formatHead, formatCount;
};

static void set_error(RDPSession *s, const char *text)
{
    if (!s) return;
    free(s->error);
    s->error = text ? strdup(text) : NULL;
}

static void report_state(RDPSession *s, RDPSessionState state, const char *detail)
{
    if (s && s->cb.state) s->cb.state(s->cb.user, state, detail);
}

static RDPSession *session_of(rdpContext *context)
{
    return context ? ((BridgeContext *)context)->session : NULL;
}

/* ---------------------------------------------------------------------- */
/* Painting                                                               */
/* ---------------------------------------------------------------------- */

static void mark_full_dirty(RDPSession *s)
{
    s->dirty = true;
    s->fullDirty = true;
}

/* As SdlContext::beginPaint: reset the invalid region for the new frame. */
static BOOL bridge_begin_paint(rdpContext *context)
{
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return TRUE;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
    return TRUE;
}

/* As SdlContext::endPaint: collect what changed. Copying happens in the
   session loop, at most once per FRAME_MIN_INTERVAL_MS, not once per paint. */
static BOOL bridge_end_paint(rdpContext *context)
{
    RDPSession *s = session_of(context);
    rdpGdi *gdi = context->gdi;
    if (!s || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
        return TRUE;

    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (gdi->suppressOutput || hwnd->invalid->null || hwnd->ninvalid < 1)
        return TRUE;

    pthread_mutex_lock(&s->gdiLock);
    for (INT32 i = 0; i < hwnd->ninvalid; i++) {
        const GDI_RGN *r = &hwnd->cinvalid[i];
        if (r->w <= 0 || r->h <= 0) continue;
        int32_t right = r->x + r->w, bottom = r->y + r->h;
        if (!s->dirty) {
            s->dirtyLeft = r->x; s->dirtyTop = r->y;
            s->dirtyRight = right; s->dirtyBottom = bottom;
            s->dirty = true;
        } else {
            if (r->x < s->dirtyLeft) s->dirtyLeft = r->x;
            if (r->y < s->dirtyTop) s->dirtyTop = r->y;
            if (right > s->dirtyRight) s->dirtyRight = right;
            if (bottom > s->dirtyBottom) s->dirtyBottom = bottom;
        }
    }
    pthread_mutex_unlock(&s->gdiLock);
    return TRUE;
}

/* Required: gdi_ResetGraphics (libfreerdp/gdi/gfx.c) asserts this is set and
   calls it whenever the server changes the desktop size. */
static BOOL bridge_desktop_resize(rdpContext *context)
{
    RDPSession *s = session_of(context);
    rdpSettings *settings = context->settings;
    if (s) pthread_mutex_lock(&s->gdiLock);
    BOOL ok = gdi_resize(context->gdi,
                         freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth),
                         freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight));
    if (ok && s) mark_full_dirty(s);
    if (s) pthread_mutex_unlock(&s->gdiLock);
    return ok;
}

static void push_frame_locked(RDPSession *s, bool force);

/* The copy happens inside the frame callback, so the lock stays held until it
   returns: a resize on the channel thread can't free the buffer mid-copy. */
static void push_frame(RDPSession *s, bool force)
{
    pthread_mutex_lock(&s->gdiLock);
    push_frame_locked(s, force);
    pthread_mutex_unlock(&s->gdiLock);
}

static void push_frame_locked(RDPSession *s, bool force)
{
    rdpGdi *gdi = s->context->gdi;
    if (!s->dirty || !gdi || !gdi->primary_buffer || !s->cb.frame) return;

    uint64_t now = GetTickCount64();
    if (!force && now - s->lastFrameMs < FRAME_MIN_INTERVAL_MS) return;
    s->lastFrameMs = now;

    RDPRect rect = { 0, 0, gdi->width, gdi->height };
    bool full = s->fullDirty;
    if (!full) {
        int32_t l = s->dirtyLeft < 0 ? 0 : s->dirtyLeft;
        int32_t t = s->dirtyTop < 0 ? 0 : s->dirtyTop;
        int32_t r = s->dirtyRight > gdi->width ? gdi->width : s->dirtyRight;
        int32_t b = s->dirtyBottom > gdi->height ? gdi->height : s->dirtyBottom;
        if (r <= l || b <= t) { s->dirty = false; return; }
        rect = (RDPRect){ l, t, r - l, b - t };
    }
    s->dirty = false;
    s->fullDirty = false;
    s->cb.frame(s->cb.user, gdi->primary_buffer, gdi->width, gdi->height,
                (int)gdi->stride, rect, full);
}

/* ---------------------------------------------------------------------- */
/* Cursor, as client/SDL/SDL3/sdl_pointer.cpp                             */
/* ---------------------------------------------------------------------- */

static BOOL bridge_pointer_new(rdpContext *context, rdpPointer *pointer)
{
    RDPSession *s = session_of(context);
    BridgePointer *bp = (BridgePointer *)pointer;
    if (!s || !context->gdi) return FALSE;

    pthread_mutex_lock(&s->lock);
    bp->id = ++s->nextCursorId;
    if (bp->id == RDP_CURSOR_HIDDEN || bp->id == RDP_CURSOR_DEFAULT)
        bp->id = s->nextCursorId = 1;
    pthread_mutex_unlock(&s->lock);

    const UINT32 w = pointer->width, h = pointer->height;
    if (w == 0 || h == 0) return TRUE;
    BYTE *data = calloc((size_t)w * h, 4);
    if (!data) return FALSE;
    if (!freerdp_image_copy_from_pointer_data(data, PIXEL_FORMAT_BGRA32, 0, 0, 0, w, h,
                                              pointer->xorMaskData, pointer->lengthXorMask,
                                              pointer->andMaskData, pointer->lengthAndMask,
                                              pointer->xorBpp, &context->gdi->palette)) {
        free(data);
        return FALSE;
    }
    if (s->cb.cursorNew)
        s->cb.cursorNew(s->cb.user, bp->id, data, (int)w, (int)h,
                        (int)pointer->xPos, (int)pointer->yPos);
    free(data);
    return TRUE;
}

static void bridge_pointer_free(rdpContext *context, rdpPointer *pointer)
{
    RDPSession *s = session_of(context);
    BridgePointer *bp = (BridgePointer *)pointer;
    if (s && s->cb.cursorFree && bp->id) s->cb.cursorFree(s->cb.user, bp->id);
}

static BOOL bridge_pointer_set(rdpContext *context, rdpPointer *pointer)
{
    RDPSession *s = session_of(context);
    BridgePointer *bp = (BridgePointer *)pointer;
    if (s && s->cb.cursorSet) s->cb.cursorSet(s->cb.user, bp->id);
    return TRUE;
}

static BOOL bridge_pointer_set_null(rdpContext *context)
{
    RDPSession *s = session_of(context);
    if (s && s->cb.cursorSet) s->cb.cursorSet(s->cb.user, RDP_CURSOR_HIDDEN);
    return TRUE;
}

static BOOL bridge_pointer_set_default(rdpContext *context)
{
    RDPSession *s = session_of(context);
    if (s && s->cb.cursorSet) s->cb.cursorSet(s->cb.user, RDP_CURSOR_DEFAULT);
    return TRUE;
}

static BOOL bridge_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y)
{
    (void)context; (void)x; (void)y;
    return TRUE;   /* never warp the Mac pointer */
}

static void register_pointer(rdpContext *context)
{
    rdpPointer pointer = { 0 };
    pointer.size = sizeof(BridgePointer);
    pointer.New = bridge_pointer_new;
    pointer.Free = bridge_pointer_free;
    pointer.Set = bridge_pointer_set;
    pointer.SetNull = bridge_pointer_set_null;
    pointer.SetDefault = bridge_pointer_set_default;
    pointer.SetPosition = bridge_pointer_set_position;
    graphics_register_pointer(context->graphics, &pointer);
}

/* ---------------------------------------------------------------------- */
/* Display control                                                        */
/* ---------------------------------------------------------------------- */

static UINT bridge_disp_caps(DispClientContext *disp, UINT32 maxMonitors,
                             UINT32 factorA, UINT32 factorB)
{
    (void)maxMonitors; (void)factorA; (void)factorB;
    RDPSession *s = disp ? (RDPSession *)disp->custom : NULL;
    if (s) {
        pthread_mutex_lock(&s->lock);
        s->dispReady = true;
        pthread_mutex_unlock(&s->lock);
    }
    return CHANNEL_RC_OK;
}

static uint32_t device_scale_for(uint32_t desktop)
{
    /* MS-RDPEDISP: DeviceScaleFactor must be 100, 140 or 180. */
    if (desktop >= 180) return 180;
    if (desktop >= 140) return 140;
    return 100;
}

static void maybe_send_layout(RDPSession *s)
{
    pthread_mutex_lock(&s->lock);
    DispClientContext *disp = s->disp;
    bool ready = s->dispReady;
    int w = s->requestedWidth, h = s->requestedHeight;
    uint32_t scale = s->requestedScale;
    bool changed = w > 0 && h > 0 &&
        (w != s->sentWidth || h != s->sentHeight || scale != s->sentScale);
    uint64_t now = GetTickCount64();
    bool due = now - s->lastResizeMs >= RESIZE_MIN_INTERVAL_MS;
    pthread_mutex_unlock(&s->lock);

    if (!disp || !ready || !changed || !due || !disp->SendMonitorLayout) return;

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = (UINT32)w;
    layout.Height = (UINT32)h;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = scale;
    layout.DeviceScaleFactor = device_scale_for(scale);

    if (disp->SendMonitorLayout(disp, 1, &layout) == CHANNEL_RC_OK) {
        pthread_mutex_lock(&s->lock);
        s->sentWidth = w; s->sentHeight = h; s->sentScale = scale;
        s->lastResizeMs = now;
        pthread_mutex_unlock(&s->lock);
    }
}

/* ---------------------------------------------------------------------- */
/* Clipboard, MS-RDPECLIP                                                 */
/* ---------------------------------------------------------------------- */

static UINT send_client_caps(CliprdrClientContext *cliprdr)
{
    CLIPRDR_GENERAL_CAPABILITY_SET general = {
        CB_CAPSTYPE_GENERAL, CB_CAPSTYPE_GENERAL_LEN, CB_CAPS_VERSION_2,
        CB_USE_LONG_FORMAT_NAMES | CB_STREAM_FILECLIP_ENABLED |
            CB_FILECLIP_NO_FILE_PATHS | CB_HUGE_FILE_SUPPORT_ENABLED
    };
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    return cliprdr->ClientCapabilities(cliprdr, &caps);
}

static UINT clip_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready)
{
    (void)ready;
    RDPSession *s = (RDPSession *)cliprdr->custom;
    UINT rc = send_client_caps(cliprdr);
    if (rc != CHANNEL_RC_OK) return rc;

    pthread_mutex_lock(&s->lock);
    s->clipListSent = false;
    pthread_mutex_unlock(&s->lock);

    if (s->cb.clipReady) s->cb.clipReady(s->cb.user);

    /* A Format List is mandatory after Monitor Ready, even an empty one. */
    pthread_mutex_lock(&s->lock);
    bool sent = s->clipListSent;
    pthread_mutex_unlock(&s->lock);
    if (!sent) {
        CLIPRDR_FORMAT_LIST list = { 0 };
        list.common.msgType = CB_FORMAT_LIST;
        rc = cliprdr->ClientFormatList(cliprdr, &list);
    }
    return rc;
}

static UINT clip_server_caps(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *caps)
{
    RDPSession *s = (RDPSession *)cliprdr->custom;
    const BYTE *p = (const BYTE *)caps->capabilitySets;
    for (UINT32 i = 0; i < caps->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET *set = (const CLIPRDR_CAPABILITY_SET *)p;
        if (set->capabilitySetType == CB_CAPSTYPE_GENERAL) {
            const CLIPRDR_GENERAL_CAPABILITY_SET *g = (const CLIPRDR_GENERAL_CAPABILITY_SET *)set;
            pthread_mutex_lock(&s->lock);
            s->serverClipFlags = g->generalFlags;
            pthread_mutex_unlock(&s->lock);
        }
        if (set->capabilitySetLength == 0) break;
        p += set->capabilitySetLength;
    }
    return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list)
{
    RDPSession *s = (RDPSession *)cliprdr->custom;

    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);

    if (s->cb.clipServerFormats && list->numFormats > 0) {
        RDPClipFormat *formats = calloc(list->numFormats, sizeof(RDPClipFormat));
        if (formats) {
            for (UINT32 i = 0; i < list->numFormats; i++) {
                formats[i].id = list->formats[i].formatId;
                formats[i].name = list->formats[i].formatName;
            }
            s->cb.clipServerFormats(s->cb.user, formats, (int)list->numFormats);
            free(formats);
        }
    }
    return rc;
}

static UINT clip_server_format_list_response(CliprdrClientContext *cliprdr,
                                             const CLIPRDR_FORMAT_LIST_RESPONSE *r)
{
    (void)cliprdr; (void)r;
    return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext *cliprdr,
                                     const CLIPRDR_FORMAT_DATA_REQUEST *request)
{
    RDPSession *s = (RDPSession *)cliprdr->custom;
    uint8_t *data = NULL;
    size_t length = 0;
    bool ok = s->cb.clipProvide &&
              s->cb.clipProvide(s->cb.user, request->requestedFormatId, &data, &length) &&
              length <= UINT32_MAX;

    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = ok ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.common.dataLen = ok ? (UINT32)length : 0;
    response.requestedFormatData = ok ? data : NULL;
    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(data);
    return rc;
}

static UINT clip_server_data_response(CliprdrClientContext *cliprdr,
                                      const CLIPRDR_FORMAT_DATA_RESPONSE *response)
{
    RDPSession *s = (RDPSession *)cliprdr->custom;
    uint32_t formatId = 0;
    bool known = false;
    pthread_mutex_lock(&s->lock);
    if (s->formatCount > 0) {
        formatId = s->formatQueue[s->formatHead];
        s->formatHead = (s->formatHead + 1) % FORMAT_QUEUE_SIZE;
        s->formatCount--;
        known = true;
    }
    pthread_mutex_unlock(&s->lock);
    if (!known) return CHANNEL_RC_OK;

    bool ok = (response->common.msgFlags & CB_RESPONSE_OK) &&
              !(response->common.msgFlags & CB_RESPONSE_FAIL);
    if (s->cb.clipData)
        s->cb.clipData(s->cb.user, formatId, response->requestedFormatData,
                       ok ? response->common.dataLen : 0, ok);
    return CHANNEL_RC_OK;
}

static UINT clip_server_file_request(CliprdrClientContext *cliprdr,
                                     const CLIPRDR_FILE_CONTENTS_REQUEST *request)
{
    RDPSession *s = (RDPSession *)cliprdr->custom;
    bool sizeOnly = (request->dwFlags & FILECONTENTS_SIZE) != 0;
    uint64_t offset = ((uint64_t)request->nPositionHigh << 32) | request->nPositionLow;
    uint8_t *data = NULL;
    size_t length = 0;
    bool ok = s->cb.clipFileProvide &&
              s->cb.clipFileProvide(s->cb.user, request->listIndex, sizeOnly, offset,
                                    request->cbRequested, &data, &length) &&
              length <= UINT32_MAX;

    CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
    response.common.msgType = CB_FILECONTENTS_RESPONSE;
    response.common.msgFlags = ok ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.streamId = request->streamId;
    response.cbRequested = ok ? (UINT32)length : 0;
    response.requestedData = ok ? data : NULL;
    UINT rc = cliprdr->ClientFileContentsResponse(cliprdr, &response);
    free(data);
    return rc;
}

static UINT clip_server_file_response(CliprdrClientContext *cliprdr,
                                      const CLIPRDR_FILE_CONTENTS_RESPONSE *response)
{
    RDPSession *s = (RDPSession *)cliprdr->custom;
    bool ok = (response->common.msgFlags & CB_RESPONSE_OK) &&
              !(response->common.msgFlags & CB_RESPONSE_FAIL);
    if (s->cb.clipFileData)
        s->cb.clipFileData(s->cb.user, response->streamId, response->requestedData,
                           ok ? response->cbRequested : 0, ok);
    return CHANNEL_RC_OK;
}

static UINT clip_server_lock(CliprdrClientContext *c, const CLIPRDR_LOCK_CLIPBOARD_DATA *l)
{
    (void)c; (void)l;
    return CHANNEL_RC_OK;
}

static UINT clip_server_unlock(CliprdrClientContext *c, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *u)
{
    (void)c; (void)u;
    return CHANNEL_RC_OK;
}

static void clip_init(RDPSession *s, CliprdrClientContext *cliprdr)
{
    cliprdr->custom = s;
    cliprdr->MonitorReady = clip_monitor_ready;
    cliprdr->ServerCapabilities = clip_server_caps;
    cliprdr->ServerFormatList = clip_server_format_list;
    cliprdr->ServerFormatListResponse = clip_server_format_list_response;
    cliprdr->ServerFormatDataRequest = clip_server_data_request;
    cliprdr->ServerFormatDataResponse = clip_server_data_response;
    cliprdr->ServerFileContentsRequest = clip_server_file_request;
    cliprdr->ServerFileContentsResponse = clip_server_file_response;
    cliprdr->ServerLockClipboardData = clip_server_lock;
    cliprdr->ServerUnlockClipboardData = clip_server_unlock;

    pthread_mutex_lock(&s->lock);
    s->cliprdr = cliprdr;
    s->formatHead = s->formatCount = 0;
    pthread_mutex_unlock(&s->lock);
}

/* ---------------------------------------------------------------------- */
/* Channels                                                               */
/* ---------------------------------------------------------------------- */

static void bridge_channel_connected(void *context, const ChannelConnectedEventArgs *e)
{
    RDPSession *s = session_of((rdpContext *)context);
    if (!s || !e || !e->name) return;

    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clip_init(s, (CliprdrClientContext *)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext *disp = (DispClientContext *)e->pInterface;
        disp->custom = s;
        disp->DisplayControlCaps = bridge_disp_caps;
        pthread_mutex_lock(&s->lock);
        s->disp = disp;
        pthread_mutex_unlock(&s->lock);
    } else {
        /* GFX pipeline, video, input extensions. Without the GFX pipeline a
           modern Windows host renders nothing. */
        freerdp_client_OnChannelConnectedEventHandler(context, e);
    }
}

static void bridge_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e)
{
    RDPSession *s = session_of((rdpContext *)context);
    if (!s || !e || !e->name) return;

    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&s->lock);
        s->cliprdr = NULL;
        pthread_mutex_unlock(&s->lock);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        pthread_mutex_lock(&s->lock);
        s->disp = NULL;
        s->dispReady = false;
        pthread_mutex_unlock(&s->lock);
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(context, e);
    }
}

/* ---------------------------------------------------------------------- */
/* Instance callbacks                                                     */
/* ---------------------------------------------------------------------- */

static BOOL bridge_pre_connect(freerdp *instance)
{
    rdpContext *context = instance->context;
    /* Channels themselves are loaded by instance->LoadChannels, which
       freerdp_client_context_new sets (client/common/client.c). Loading them
       here as well would load every channel twice. */
    if (!freerdp_settings_set_uint32(context->settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH))
        return FALSE;
    if (PubSub_SubscribeChannelConnected(context->pubSub, bridge_channel_connected) < 0)
        return FALSE;
    if (PubSub_SubscribeChannelDisconnected(context->pubSub, bridge_channel_disconnected) < 0)
        return FALSE;
    return TRUE;
}

static BOOL bridge_post_connect(freerdp *instance)
{
    rdpContext *context = instance->context;
    RDPSession *s = session_of(context);

    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32))
        return FALSE;

    register_pointer(context);
    context->update->BeginPaint = bridge_begin_paint;
    context->update->EndPaint = bridge_end_paint;
    context->update->DesktopResize = bridge_desktop_resize;

    if (s) {
        pthread_mutex_lock(&s->lock);
        s->sentWidth = (int)freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
        s->sentHeight = (int)freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
        s->sentScale = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopScaleFactor);
        if (s->sentScale == 0) s->sentScale = 100;
        pthread_mutex_unlock(&s->lock);
        pthread_mutex_lock(&s->gdiLock);
        mark_full_dirty(s);
        pthread_mutex_unlock(&s->gdiLock);
        report_state(s, RDPSessionStateConnected, NULL);
    }
    return TRUE;
}

static void bridge_post_disconnect(freerdp *instance)
{
    gdi_free(instance);
}

/* Credentials are put in the settings up front. Returning FALSE stops the
   library from falling back to a terminal prompt, which would hang a GUI app.
   It is only consulted when a username or password is empty
   (utils_authenticate in libfreerdp/core/utils.c). */
static BOOL bridge_authenticate_ex(freerdp *instance, char **username, char **password,
                                   char **domain, rdp_auth_reason reason)
{
    (void)instance; (void)username; (void)password; (void)domain; (void)reason;
    return FALSE;
}

/* FreeRDP only gets here for a certificate it could not verify itself: not
   signed by a CA in /etc/ssl/cert.pem and not stored from an earlier
   connection. The user decides. Without anyone to ask, it is refused. */
static DWORD bridge_ask_certificate(freerdp *instance, const RDPCertificate *certificate)
{
    RDPSession *s = session_of(instance->context);
    if (!s || !s->cb.certificate)
        return RDP_CERT_REFUSE;
    uint32_t answer = s->cb.certificate(s->cb.user, certificate);
    return answer <= RDP_CERT_TRUST_ONCE ? answer : RDP_CERT_REFUSE;
}

static DWORD bridge_verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                       const char *common_name, const char *subject,
                                       const char *issuer, const char *fingerprint, DWORD flags)
{
    RDPCertificate certificate = {
        .host = host, .port = port, .commonName = common_name, .subject = subject,
        .issuer = issuer, .fingerprint = fingerprint,
        .isPEM = (flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0,
        .gateway = (flags & VERIFY_CERT_FLAG_GATEWAY) != 0,
        .mismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0,
    };
    return bridge_ask_certificate(instance, &certificate);
}

static DWORD bridge_verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                               const char *common_name, const char *subject,
                                               const char *issuer, const char *fingerprint,
                                               const char *old_subject, const char *old_issuer,
                                               const char *old_fingerprint, DWORD flags)
{
    /* FreeRDP passes the old certificate in the same form as the new one. */
    bool pem = (flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0;
    RDPCertificate certificate = {
        .host = host, .port = port, .commonName = common_name, .subject = subject,
        .issuer = issuer, .fingerprint = fingerprint, .isPEM = pem,
        .gateway = (flags & VERIFY_CERT_FLAG_GATEWAY) != 0, .changed = true,
        .mismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0,
        .oldSubject = old_subject, .oldIssuer = old_issuer, .oldFingerprint = old_fingerprint,
        .oldIsPEM = pem,
    };
    return bridge_ask_certificate(instance, &certificate);
}

static BOOL bridge_gateway_message(freerdp *instance, UINT32 type, BOOL isDisplayMandatory,
                                   BOOL isConsentMandatory, size_t length, const WCHAR *message)
{
    (void)instance; (void)type; (void)isDisplayMandatory; (void)isConsentMandatory;
    (void)length; (void)message;
    return TRUE;
}

/* ---------------------------------------------------------------------- */
/* Client entry points                                                    */
/* ---------------------------------------------------------------------- */

static BOOL bridge_client_new(freerdp *instance, rdpContext *context)
{
    (void)context;
    instance->PreConnect = bridge_pre_connect;
    instance->PostConnect = bridge_post_connect;
    instance->PostDisconnect = bridge_post_disconnect;
    instance->AuthenticateEx = bridge_authenticate_ex;
    instance->VerifyCertificateEx = bridge_verify_certificate;
    instance->VerifyChangedCertificateEx = bridge_verify_changed_certificate;
    instance->PresentGatewayMessage = bridge_gateway_message;
    return TRUE;
}

static void bridge_client_free(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }
static int bridge_client_start(rdpContext *context) { (void)context; return 0; }
static int bridge_client_stop(rdpContext *context) { (void)context; return 0; }
static BOOL bridge_global_init(void) { return TRUE; }
static void bridge_global_uninit(void) {}

/* ---------------------------------------------------------------------- */
/* Session thread                                                         */
/* ---------------------------------------------------------------------- */

static DWORD WINAPI session_thread(LPVOID arg)
{
    RDPSession *s = (RDPSession *)arg;
    rdpContext *context = s->context;
    freerdp *instance = context->instance;

    report_state(s, RDPSessionStateConnecting, NULL);

    if (!freerdp_connect(instance)) {
        UINT32 code = freerdp_get_last_error(context);
        const char *name = freerdp_get_last_error_name(code);
        if (s->stopping) {
            report_state(s, RDPSessionStateDisconnected, NULL);
        } else {
            set_error(s, name);
            report_state(s, RDPSessionStateFailed, name);
        }
        return 1;
    }

    while (!s->stopping && !freerdp_shall_disconnect_context(context)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
        DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
        if (count == 0) break;

        DWORD timeout = s->dirty ? FRAME_MIN_INTERVAL_MS : 50;
        if (WaitForMultipleObjects(count, handles, FALSE, timeout) == WAIT_FAILED) break;

        if (!freerdp_check_event_handles(context)) {
            UINT32 code = freerdp_get_last_error(context);
            if (code != FREERDP_ERROR_SUCCESS && !s->stopping)
                set_error(s, freerdp_get_last_error_name(code));
            break;
        }

        maybe_send_layout(s);
        push_frame(s, false);
    }

    if (!s->stopping && !s->error) {
        UINT32 code = freerdp_get_last_error(context);
        if (code != FREERDP_ERROR_SUCCESS)
            set_error(s, freerdp_get_last_error_name(code));
    }

    freerdp_disconnect(instance);

    if (s->stopping) {
        set_error(s, NULL);
        report_state(s, RDPSessionStateDisconnected, NULL);
    } else {
        report_state(s, s->error ? RDPSessionStateFailed : RDPSessionStateDisconnected, s->error);
    }
    return 0;
}

/* ---------------------------------------------------------------------- */
/* Public surface                                                         */
/* ---------------------------------------------------------------------- */

static bool set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value)
{
    if (!value || !*value) return true;
    return freerdp_settings_set_string(settings, key, value);
}

RDPSession *rdp_session_create(const char *const *argv, int argc,
                               const RDPCredentials *creds, const RDPCallbacks *callbacks)
{
    RDP_CLIENT_ENTRY_POINTS entry = { 0 };
    entry.Size = sizeof(entry);
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.GlobalInit = bridge_global_init;
    entry.GlobalUninit = bridge_global_uninit;
    entry.ContextSize = sizeof(BridgeContext);
    entry.ClientNew = bridge_client_new;
    entry.ClientFree = bridge_client_free;
    entry.ClientStart = bridge_client_start;
    entry.ClientStop = bridge_client_stop;

    RDPSession *s = calloc(1, sizeof(RDPSession));
    if (!s) return NULL;
    pthread_mutex_init(&s->lock, NULL);
    pthread_mutex_init(&s->gdiLock, NULL);
    if (callbacks) s->cb = *callbacks;

    rdpContext *context = freerdp_client_context_new(&entry);
    if (!context) {
        set_error(s, "FreeRDP could not create a client context");
        return s;
    }
    ((BridgeContext *)context)->session = s;
    s->context = context;

    rdpSettings *settings = context->settings;
    if (freerdp_client_settings_parse_command_line(settings, argc, (char **)argv, FALSE) != 0) {
        set_error(s, "FreeRDP rejected the connection settings");
        return s;
    }
    /* Hand the certificate callback the certificate and its chain, not just a
       fingerprint, so the app can ask macOS whether it trusts them. */
    if (!freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE)) {
        set_error(s, "could not configure certificate checking");
        return s;
    }

    if (creds) {
        bool separate = creds->gatewayUsername && *creds->gatewayUsername;
        bool ok = set_string(settings, FreeRDP_Username, creds->username) &&
                  set_string(settings, FreeRDP_Domain, creds->domain) &&
                  set_string(settings, FreeRDP_Password, creds->password);
        if (separate) {
            ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, FALSE) &&
                 set_string(settings, FreeRDP_GatewayUsername, creds->gatewayUsername) &&
                 set_string(settings, FreeRDP_GatewayDomain, creds->gatewayDomain) &&
                 set_string(settings, FreeRDP_GatewayPassword, creds->gatewayPassword);
        } else {
            ok = ok && freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, TRUE) &&
                 set_string(settings, FreeRDP_GatewayUsername, creds->username) &&
                 set_string(settings, FreeRDP_GatewayDomain, creds->domain) &&
                 set_string(settings, FreeRDP_GatewayPassword, creds->password);
        }
        if (creds->scaleFactor >= 100 && creds->scaleFactor <= 500) {
            ok = ok &&
                 freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, creds->scaleFactor) &&
                 freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor,
                                             device_scale_for(creds->scaleFactor));
        }
        if (!ok) set_error(s, "could not apply the credentials");
    }
    return s;
}

bool rdp_session_start(RDPSession *s)
{
    if (!s || !s->context || s->error) return false;
    s->stopping = false;
    s->thread = CreateThread(NULL, 0, session_thread, s, 0, NULL);
    return s->thread != NULL;
}

void rdp_session_stop(RDPSession *s)
{
    if (!s) return;
    s->stopping = true;
    if (s->context) freerdp_abort_connect_context(s->context);
    if (s->thread) {
        WaitForSingleObject(s->thread, 10000);
        CloseHandle(s->thread);
        s->thread = NULL;
    }
}

void rdp_session_free(RDPSession *s)
{
    if (!s) return;
    rdp_session_stop(s);
    if (s->context) freerdp_client_context_free(s->context);
    free(s->error);
    pthread_mutex_destroy(&s->lock);
    pthread_mutex_destroy(&s->gdiLock);
    free(s);
}

const char *rdp_session_error(RDPSession *s)
{
    return s ? s->error : NULL;
}

void rdp_session_request_size(RDPSession *s, int width, int height, uint32_t scale)
{
    if (!s) return;
    width &= ~1;
    if (width < DISPLAY_CONTROL_MIN_MONITOR_WIDTH) width = DISPLAY_CONTROL_MIN_MONITOR_WIDTH;
    if (width > DISPLAY_CONTROL_MAX_MONITOR_WIDTH) width = DISPLAY_CONTROL_MAX_MONITOR_WIDTH;
    if (height < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT) height = DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
    if (height > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT) height = DISPLAY_CONTROL_MAX_MONITOR_HEIGHT;
    if (scale < 100 || scale > 500) scale = 100;
    pthread_mutex_lock(&s->lock);
    s->requestedWidth = width;
    s->requestedHeight = height;
    s->requestedScale = scale;
    pthread_mutex_unlock(&s->lock);
}

bool rdp_session_can_resize(RDPSession *s)
{
    if (!s) return false;
    pthread_mutex_lock(&s->lock);
    bool ready = s->disp && s->dispReady;
    pthread_mutex_unlock(&s->lock);
    return ready;
}

void rdp_session_send_mouse(RDPSession *s, uint16_t flags, uint16_t x, uint16_t y)
{
    if (!s || !s->context || !s->context->input) return;
    freerdp_input_send_mouse_event(s->context->input, flags, x, y);
}

/* MS-RDPBCGR 2.2.8.1.1.3.1.1.3: WheelRotationMask is 9 bits, negative values
   carry PTRFLAGS_WHEEL_NEGATIVE and are sign extended at the server. */
uint16_t rdp_wheel_flags(bool horizontal, int step)
{
    if (step > 255) step = 255;
    if (step < -256) step = -256;
    uint16_t flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
    if (step < 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE | (uint16_t)(0x200 + step);
    else flags |= (uint16_t)step;
    return flags;
}

void rdp_session_send_wheel(RDPSession *s, bool horizontal, int units)
{
    if (!s || !s->context || !s->context->input || units == 0) return;
    while (units != 0) {
        int step = units > 0 ? (units > 255 ? 255 : units) : (units < -256 ? -256 : units);
        units -= step;
        freerdp_input_send_mouse_event(s->context->input, rdp_wheel_flags(horizontal, step), 0, 0);
    }
}

void rdp_session_send_xbutton(RDPSession *s, int button, bool down, uint16_t x, uint16_t y)
{
    if (!s || !s->context || !s->context->input) return;
    uint16_t flags = (button == 1) ? PTR_XFLAGS_BUTTON1 : PTR_XFLAGS_BUTTON2;
    if (down) flags |= PTR_XFLAGS_DOWN;
    freerdp_input_send_extended_mouse_event(s->context->input, flags, x, y);
}

void rdp_session_send_key(RDPSession *s, uint16_t scancode, bool down, bool repeat)
{
    if (!s || !s->context || !s->context->input || scancode == 0) return;
    freerdp_input_send_keyboard_event_ex(s->context->input, down, repeat, scancode);
}

void rdp_session_send_locks(RDPSession *s, bool capsLock, bool numLock)
{
    if (!s || !s->context || !s->context->input) return;
    UINT32 flags = (capsLock ? KBD_SYNC_CAPS_LOCK : 0) | (numLock ? KBD_SYNC_NUM_LOCK : 0);
    freerdp_input_send_synchronize_event(s->context->input, flags);
}

bool rdp_session_send_unicode(RDPSession *s, uint16_t code, bool down)
{
    if (!s || !s->context || !s->context->input) return false;
    if (!freerdp_settings_get_bool(s->context->settings, FreeRDP_UnicodeInput)) return false;
    return freerdp_input_send_unicode_keyboard_event(s->context->input,
                                                     down ? 0 : KBD_FLAGS_RELEASE, code);
}

bool rdp_session_clip_announce(RDPSession *s, const RDPClipFormat *formats, int count)
{
    if (!s) return false;
    pthread_mutex_lock(&s->lock);
    CliprdrClientContext *cliprdr = s->cliprdr;
    s->clipListSent = true;
    pthread_mutex_unlock(&s->lock);
    if (!cliprdr) return false;

    CLIPRDR_FORMAT *list = count > 0 ? calloc((size_t)count, sizeof(CLIPRDR_FORMAT)) : NULL;
    if (count > 0 && !list) return false;
    for (int i = 0; i < count; i++) {
        list[i].formatId = formats[i].id;
        list[i].formatName = (char *)formats[i].name;
    }
    CLIPRDR_FORMAT_LIST message = { 0 };
    message.common.msgType = CB_FORMAT_LIST;
    message.numFormats = (UINT32)count;
    message.formats = list;
    UINT rc = cliprdr->ClientFormatList(cliprdr, &message);
    free(list);
    return rc == CHANNEL_RC_OK;
}

bool rdp_session_clip_request(RDPSession *s, uint32_t formatId)
{
    if (!s) return false;
    pthread_mutex_lock(&s->lock);
    CliprdrClientContext *cliprdr = s->cliprdr;
    if (!cliprdr || s->formatCount >= FORMAT_QUEUE_SIZE) {
        pthread_mutex_unlock(&s->lock);
        return false;
    }
    int tail = (s->formatHead + s->formatCount) % FORMAT_QUEUE_SIZE;
    s->formatQueue[tail] = formatId;
    s->formatCount++;
    pthread_mutex_unlock(&s->lock);

    CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
    request.common.msgType = CB_FORMAT_DATA_REQUEST;
    request.requestedFormatId = formatId;
    if (cliprdr->ClientFormatDataRequest(cliprdr, &request) == CHANNEL_RC_OK)
        return true;

    /* Undo the queue entry, nothing will answer it. */
    pthread_mutex_lock(&s->lock);
    if (s->formatCount > 0) s->formatCount--;
    pthread_mutex_unlock(&s->lock);
    return false;
}

bool rdp_session_clip_request_file(RDPSession *s, uint32_t streamId, uint32_t listIndex,
                                   bool sizeOnly, uint64_t offset, uint32_t count)
{
    if (!s) return false;
    pthread_mutex_lock(&s->lock);
    CliprdrClientContext *cliprdr = s->cliprdr;
    pthread_mutex_unlock(&s->lock);
    if (!cliprdr) return false;

    CLIPRDR_FILE_CONTENTS_REQUEST request = { 0 };
    request.common.msgType = CB_FILECONTENTS_REQUEST;
    request.streamId = streamId;
    request.listIndex = listIndex;
    request.dwFlags = sizeOnly ? FILECONTENTS_SIZE : FILECONTENTS_RANGE;
    request.nPositionLow = (UINT32)(offset & 0xFFFFFFFFu);
    request.nPositionHigh = (UINT32)(offset >> 32);
    /* MS-RDPECLIP 2.2.5.3: a size request asks for exactly 8 bytes. */
    request.cbRequested = sizeOnly ? 8 : count;
    return cliprdr->ClientFileContentsRequest(cliprdr, &request) == CHANNEL_RC_OK;
}

uint32_t rdp_session_clip_server_flags(RDPSession *s)
{
    if (!s) return 0;
    pthread_mutex_lock(&s->lock);
    uint32_t flags = s->serverClipFlags;
    pthread_mutex_unlock(&s->lock);
    return flags;
}

void rdp_copy_rect_opaque(uint8_t *dst, size_t dstStride, const uint8_t *src, size_t srcStride,
                          int x, int y, int width, int height)
{
    for (int row = 0; row < height; row++) {
        uint32_t *d = (uint32_t *)(dst + (size_t)(y + row) * dstStride + (size_t)x * 4);
        const uint32_t *p = (const uint32_t *)(src + (size_t)(y + row) * srcStride + (size_t)x * 4);
        for (int col = 0; col < width; col++)
            d[col] = p[col] | 0xFF000000u;
    }
}

uint16_t rdp_scancode_for_mac_keycode(uint16_t keyCode, bool iso)
{
    /* kVK_ISO_Section (0x0A) and kVK_ANSI_Grave (0x32) are swapped on ISO
       keyboards. MacFreeRDP fixKeyCode in client/Mac/MRDPView.m does the same. */
    if (iso) {
        if (keyCode == 0x0A) keyCode = 0x32;
        else if (keyCode == 0x32) keyCode = 0x0A;
    }
    DWORD vk = GetVirtualKeyCodeFromKeycode(keyCode, WINPR_KEYCODE_TYPE_APPLE);
    if (vk == 0 || vk == 0xFF) return 0;
    DWORD sc = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
    return (uint16_t)sc;
}

/* KBGetLayoutType is exported by HIToolbox but no longer declared in its
   headers. Checked on this machine: it returns 'ISO ' for the built-in
   keyboard.
   Declared here instead of including Carbon, whose headers clash with
   WinPR's (both define CreateEvent). Signatures from HIToolbox Events.h. */
extern uint32_t KBGetLayoutType(int16_t iKeyboardType);
extern uint8_t LMGetKbdType(void);

bool rdp_mac_keyboard_is_iso(void)
{
    return KBGetLayoutType((int16_t)LMGetKbdType()) == 0x49534F20u; /* 'ISO ' */
}

const char *rdp_freerdp_version(void)
{
    return freerdp_get_version_string();
}
