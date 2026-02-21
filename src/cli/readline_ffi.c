#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <moonbit.h>

/* Simple line history (no libreadline dependency). */

#define MAX_HISTORY 500
#define MAX_LINE 4096

static char *history[MAX_HISTORY];
static int history_count = 0;

/* Read a line with prompt. Two-pass pattern.
   buf_size=0: returns length needed. buf_size>0: fills buffer. */
MOONBIT_FFI_EXPORT
int32_t cub_readline(const char *prompt, char *buf, int32_t buf_size) {
    static char line_buf[MAX_LINE];
    static int32_t last_len = 0;

    if (buf_size == 0) {
        /* First pass: read the line */
        if (prompt && *prompt) {
            fputs(prompt, stdout);
            fflush(stdout);
        }
        if (!fgets(line_buf, MAX_LINE, stdin)) {
            return -1; /* EOF */
        }
        /* Strip trailing newline */
        last_len = (int32_t)strlen(line_buf);
        while (last_len > 0 && (line_buf[last_len-1] == '\n' || line_buf[last_len-1] == '\r')) {
            line_buf[--last_len] = '\0';
        }
        return last_len;
    }

    /* Second pass: copy to buffer */
    int32_t to_copy = last_len < buf_size ? last_len : buf_size;
    memcpy(buf, line_buf, to_copy);
    return to_copy;
}

/* Add a line to in-memory history. */
MOONBIT_FFI_EXPORT
void cub_add_history(const char *line) {
    if (!line || !*line) return;
    if (history_count >= MAX_HISTORY) {
        free(history[0]);
        memmove(history, history + 1, (MAX_HISTORY - 1) * sizeof(char*));
        history_count--;
    }
    history[history_count++] = strdup(line);
}

/* Load history from file. Returns 0 on success. */
MOONBIT_FFI_EXPORT
int32_t cub_read_history(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[MAX_LINE];
    while (fgets(line, MAX_LINE, f)) {
        int len = (int)strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';
        if (len > 0)
            cub_add_history(line);
    }
    fclose(f);
    return 0;
}

/* Write history to file. Returns 0 on success. */
MOONBIT_FFI_EXPORT
int32_t cub_write_history(const char *path) {
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    for (int i = 0; i < history_count; i++) {
        fputs(history[i], f);
        fputc('\n', f);
    }
    fclose(f);
    return 0;
}
