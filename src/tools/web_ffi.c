#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <moonbit.h>

/* Simple HTTP GET using libcurl.
   Two-pass pattern: call with buf_size=0 to get content length,
   then call again with a buffer to fill.
   Returns content size on success, -1 on error. */

struct fetch_buf {
  char *data;
  size_t size;
  size_t capacity;
};

static size_t write_callback(void *contents, size_t size, size_t nmemb,
                             void *userp) {
  size_t total = size * nmemb;
  struct fetch_buf *buf = (struct fetch_buf *)userp;
  if (buf->size + total > buf->capacity) {
    size_t new_cap = (buf->capacity == 0) ? 4096 : buf->capacity;
    while (new_cap < buf->size + total) {
      new_cap *= 2;
    }
    char *new_data = realloc(buf->data, new_cap);
    if (!new_data)
      return 0;
    buf->data = new_data;
    buf->capacity = new_cap;
  }
  memcpy(buf->data + buf->size, contents, total);
  buf->size += total;
  return total;
}

/* We store the last fetched result in a static buffer so the
   two-pass pattern works (first call fetches, second copies). */
static struct fetch_buf last_result = {NULL, 0, 0};
static char last_url[4096] = {0};

MOONBIT_FFI_EXPORT
int32_t cub_web_fetch(const char *url, char *buf, int32_t buf_size) {
  /* If buf_size > 0 and we have cached data for this URL, copy it */
  if (buf_size > 0 && buf != NULL && last_result.data != NULL &&
      strcmp(url, last_url) == 0) {
    int32_t to_copy =
        (int32_t)last_result.size < buf_size ? (int32_t)last_result.size : buf_size;
    memcpy(buf, last_result.data, to_copy);
    return to_copy;
  }

  /* Use curl command-line as a portable fallback (no libcurl linking needed) */
  char cmd[8192];
  snprintf(cmd, sizeof(cmd),
           "curl -sL -m 30 -A 'cub/1.0' --max-filesize 1048576 '%s' 2>/dev/null",
           url);

  FILE *fp = popen(cmd, "r");
  if (!fp) {
    return -1;
  }

  /* Free previous result */
  if (last_result.data) {
    free(last_result.data);
    last_result.data = NULL;
    last_result.size = 0;
    last_result.capacity = 0;
  }

  /* Read all output */
  char chunk[4096];
  size_t n;
  while ((n = fread(chunk, 1, sizeof(chunk), fp)) > 0) {
    write_callback(chunk, 1, n, &last_result);
  }
  int status = pclose(fp);
  if (status != 0 && last_result.size == 0) {
    return -1;
  }

  /* Cache the URL */
  strncpy(last_url, url, sizeof(last_url) - 1);
  last_url[sizeof(last_url) - 1] = '\0';

  if (buf_size > 0 && buf != NULL) {
    int32_t to_copy =
        (int32_t)last_result.size < buf_size ? (int32_t)last_result.size : buf_size;
    memcpy(buf, last_result.data, to_copy);
    return to_copy;
  }

  return (int32_t)last_result.size;
}
