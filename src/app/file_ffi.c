#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <moonbit.h>

/* Read file into buffer. Returns file size, or -1 on error.
   If buf_size is 0, just returns the size needed. */
MOONBIT_FFI_EXPORT
int32_t cub_read_file(const char *path, char *buf, int32_t buf_size) {
  FILE *f = fopen(path, "r");
  if (!f) {
    return -1;
  }
  fseek(f, 0, SEEK_END);
  long file_size = ftell(f);
  fseek(f, 0, SEEK_SET);

  if (file_size < 0) {
    fclose(f);
    return -1;
  }

  if (buf_size > 0 && buf != NULL) {
    int32_t to_read = file_size < buf_size ? (int32_t)file_size : buf_size;
    size_t read_len = fread(buf, 1, to_read, f);
    fclose(f);
    return (int32_t)read_len;
  }

  fclose(f);
  return (int32_t)file_size;
}

/* Write content to file. Returns bytes written, or -1 on error. */
MOONBIT_FFI_EXPORT
int32_t cub_write_file(const char *path, const char *data, int32_t data_len) {
  FILE *f = fopen(path, "w");
  if (!f) {
    return -1;
  }
  size_t written = fwrite(data, 1, data_len, f);
  fclose(f);
  return (int32_t)written;
}

/* List directory entries as newline-separated string. Two-pass pattern. */
MOONBIT_FFI_EXPORT
int32_t cub_list_dir(const char *path, char *buf, int32_t buf_size) {
    DIR *d = opendir(path);
    if (!d) return -1;

    /* Build result string */
    char tmp[65536];
    int pos = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue; /* skip hidden */
        int len = (int)strlen(ent->d_name);
        if (pos + len + 1 >= (int)sizeof(tmp)) break;
        memcpy(tmp + pos, ent->d_name, len);
        pos += len;
        tmp[pos++] = '\n';
    }
    closedir(d);

    if (buf_size == 0) return pos;
    int to_copy = pos < buf_size ? pos : buf_size;
    memcpy(buf, tmp, to_copy);
    return to_copy;
}
