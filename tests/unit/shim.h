#include "rdpbridge.h"
int shim_parse_file_list(const uint8_t *data, uint32_t len, char *names, uint32_t *attrs, uint64_t *sizes, int max);
int shim_serialize_file_list(const char *const *names, const uint32_t *attrs, const uint64_t *sizes, int n, uint8_t **out, uint32_t *outLen);
int shim_h264_decode(const uint8_t *annexB, uint32_t length, uint32_t width, uint32_t height, uint8_t *bgra);
int shim_md4(const uint8_t *data, size_t length, uint8_t out[16]);
int shim_rc4(const uint8_t *key, size_t keyLength, const uint8_t *data, size_t length, uint8_t *out);
void shim_log(const char *tag, unsigned level, const char *text);
