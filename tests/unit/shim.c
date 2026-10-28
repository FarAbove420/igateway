#include <freerdp/utils/cliprdr_utils.h>
#include <freerdp/channels/cliprdr.h>
#include <winpr/shell.h>
#include <winpr/string.h>
#include <stdlib.h>
#include <string.h>
int shim_parse_file_list(const uint8_t *data, uint32_t len, char *names, uint32_t *attrs, uint64_t *sizes, int max) {
  FILEDESCRIPTORW *list = NULL; UINT32 count = 0;
  if (cliprdr_parse_file_list(data, len, &list, &count) != 0) return -1;
  for (UINT32 i = 0; i < count && (int)i < max; i++) {
    ConvertWCharToUtf8(list[i].cFileName, names + (size_t)i * 260, 260);
    attrs[i] = list[i].dwFileAttributes;
    sizes[i] = ((uint64_t)list[i].nFileSizeHigh << 32) | list[i].nFileSizeLow;
  }
  free(list); return (int)count;
}
int shim_serialize_file_list(const char *const *names, const uint32_t *attrs, const uint64_t *sizes, int n, uint8_t **out, uint32_t *outLen) {
  FILEDESCRIPTORW *list = calloc((size_t)n, sizeof(FILEDESCRIPTORW));
  for (int i = 0; i < n; i++) {
    list[i].dwFlags = FD_ATTRIBUTES | FD_FILESIZE;
    list[i].dwFileAttributes = attrs[i];
    list[i].nFileSizeHigh = (DWORD)(sizes[i] >> 32); list[i].nFileSizeLow = (DWORD)(sizes[i] & 0xFFFFFFFF);
    ConvertUtf8ToWChar(names[i], list[i].cFileName, 260);
  }
  UINT rc = cliprdr_serialize_file_list_ex(CB_STREAM_FILECLIP_ENABLED | CB_HUGE_FILE_SUPPORT_ENABLED, list, (UINT32)n, out, outLen);
  free(list); return (int)rc;
}

#include <freerdp/codec/h264.h>
#include <freerdp/codec/color.h>
/* Decodes one H.264 Annex B frame through FreeRDP's AVC420 path into BGRA.
   Returns FreeRDP's status: >= 0 is success. */
int shim_h264_decode(const uint8_t *annexB, uint32_t length, uint32_t width, uint32_t height, uint8_t *bgra) {
  H264_CONTEXT *h264 = h264_context_new(FALSE);
  if (!h264) return -1000;
  if (!h264_context_reset(h264, width, height)) { h264_context_free(h264); return -1001; }
  RECTANGLE_16 rect = { 0, 0, (UINT16)width, (UINT16)height };
  int status = avc420_decompress(h264, annexB, length, bgra, PIXEL_FORMAT_BGRA32, width * 4, width, height, &rect, 1);
  h264_context_free(h264);
  return status;
}

#include <winpr/crypto.h>
/* MD4 and RC4 through WinPR, as NTLM uses them. 1 on success. */
int shim_md4(const uint8_t *data, size_t length, uint8_t out[16]) {
  return winpr_Digest(WINPR_MD_MD4, data, length, out, 16) ? 1 : 0;
}
int shim_rc4(const uint8_t *key, size_t keyLength, const uint8_t *data, size_t length, uint8_t *out) {
  WINPR_RC4_CTX *rc4 = winpr_RC4_New(key, keyLength);
  if (!rc4) return 0;
  BOOL ok = winpr_RC4_Update(rc4, length, data, out);
  winpr_RC4_Free(rc4);
  return ok ? 1 : 0;
}

#include <winpr/wlog.h>
/* Logs a line the way FreeRDP code does, under the given tag. */
void shim_log(const char *tag, unsigned level, const char *text) {
  WLog_Print(WLog_Get(tag), level, "%s", text);
}
