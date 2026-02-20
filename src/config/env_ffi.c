#include <stdlib.h>
#include <string.h>
#include <moonbit.h>

/* Copy environment variable value into a MoonBit Bytes buffer.
   Returns the length of the value, or -1 if not set.
   If buf_size is 0, just returns the length needed. */
MOONBIT_FFI_EXPORT
int32_t cub_getenv(const char *name, char *buf, int32_t buf_size) {
  const char *val = getenv(name);
  if (val == NULL) {
    return -1;
  }
  int32_t len = (int32_t)strlen(val);
  if (buf_size > 0 && buf != NULL) {
    int32_t copy_len = len < buf_size ? len : buf_size;
    memcpy(buf, val, copy_len);
  }
  return len;
}
