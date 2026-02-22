#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <moonbit.h>

/* List directory entries as newline-separated string. Two-pass pattern.
   Unique name to avoid linker conflicts with other packages. */
MOONBIT_FFI_EXPORT
int32_t cub_ext_list_dir(const char *path, char *buf, int32_t buf_size) {
  DIR *d = opendir(path);
  if (!d) return -1;

  char tmp[65536];
  int pos = 0;
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    if (ent->d_name[0] == '.') continue;
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

/* Read file into buffer. Two-pass pattern.
   Unique name to avoid linker conflicts with other packages. */
MOONBIT_FFI_EXPORT
int32_t cub_ext_read_file(const char *path, char *buf, int32_t buf_size) {
  FILE *f = fopen(path, "r");
  if (!f) return -1;

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
