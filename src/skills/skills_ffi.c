#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <moonbit.h>

/* List directory entries as newline-separated names.
   Returns total size needed, or -1 on error.
   If buf_size is 0, just returns the size needed. */
MOONBIT_FFI_EXPORT
int32_t cub_skills_list_dir(const char *path, char *buf, int32_t buf_size) {
  DIR *d = opendir(path);
  if (!d) {
    return -1;
  }
  int32_t total = 0;
  int32_t written = 0;
  struct dirent *ent;
  int first = 1;
  while ((ent = readdir(d)) != NULL) {
    /* Skip . and .. */
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
      continue;
    }
    int32_t name_len = (int32_t)strlen(ent->d_name);
    int32_t needed = (first ? 0 : 1) + name_len; /* newline separator + name */
    if (buf_size > 0 && buf != NULL && written + needed <= buf_size) {
      if (!first) {
        buf[written] = '\n';
        written++;
      }
      memcpy(buf + written, ent->d_name, name_len);
      written += name_len;
    }
    total += needed;
    first = 0;
  }
  closedir(d);
  return total;
}

/* Read file into buffer. Returns file size, or -1 on error.
   If buf_size is 0, just returns the size needed. */
MOONBIT_FFI_EXPORT
int32_t cub_skills_read_file(const char *path, char *buf, int32_t buf_size) {
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
