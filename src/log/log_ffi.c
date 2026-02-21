#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

/* Write a message to stderr followed by newline. */
int32_t cub_write_stderr(const char *buf, int32_t len) {
    if (len <= 0) return 0;
    int32_t written = (int32_t)write(STDERR_FILENO, buf, (size_t)len);
    if (write(STDERR_FILENO, "\n", 1) < 0) { /* ignore */ }
    return written;
}
