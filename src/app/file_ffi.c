#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
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

/* Recursively create directories. Returns 0 on success, -1 on error. */
MOONBIT_FFI_EXPORT
int32_t cub_mkdir_p(const char *path) {
  char tmp[4096];
  int len = (int)snprintf(tmp, sizeof(tmp), "%s", path);
  if (len <= 0 || len >= (int)sizeof(tmp)) return -1;
  /* Remove trailing slash */
  if (tmp[len - 1] == '/') tmp[len - 1] = '\0';
  for (char *p = tmp + 1; *p; p++) {
    if (*p == '/') {
      *p = '\0';
      mkdir(tmp, 0755);
      *p = '/';
    }
  }
  return mkdir(tmp, 0755) == 0 || errno == EEXIST ? 0 : -1;
}

/* Simple HTTP GET via socket. Two-pass pattern like other FFI functions.
   Used for Ollama auto-detection (localhost only). */
MOONBIT_FFI_EXPORT
int32_t cub_http_get(const char *url, char *buf, int32_t buf_size) {
  /* Only support http:// URLs */
  if (strncmp(url, "http://", 7) != 0) return -1;

  /* Parse host:port/path */
  const char *hoststart = url + 7;
  const char *pathstart = strchr(hoststart, '/');
  if (!pathstart) pathstart = "/";

  char host[256];
  int port = 80;
  const char *colon = strchr(hoststart, ':');
  if (colon && colon < pathstart) {
    int hlen = (int)(colon - hoststart);
    if (hlen >= (int)sizeof(host)) return -1;
    memcpy(host, hoststart, hlen);
    host[hlen] = '\0';
    port = atoi(colon + 1);
  } else {
    int hlen = (int)(pathstart - hoststart);
    if (hlen >= (int)sizeof(host)) return -1;
    memcpy(host, hoststart, hlen);
    host[hlen] = '\0';
  }

  /* Connect via socket */
  struct hostent *he = gethostbyname(host);
  if (!he) return -1;

  int sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0) return -1;

  /* Set 2 second timeout */
  struct timeval tv = {2, 0};
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);

  if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    close(sock);
    return -1;
  }

  /* Send HTTP request */
  char req[1024];
  int rlen = snprintf(req, sizeof(req),
    "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n",
    pathstart, host);
  if (send(sock, req, rlen, 0) < 0) {
    close(sock);
    return -1;
  }

  /* Read full response */
  static char resp[65536];
  int total = 0;
  while (total < (int)sizeof(resp) - 1) {
    int n = recv(sock, resp + total, sizeof(resp) - 1 - total, 0);
    if (n <= 0) break;
    total += n;
  }
  resp[total] = '\0';
  close(sock);

  /* Find body after \r\n\r\n */
  char *body = strstr(resp, "\r\n\r\n");
  if (!body) return -1;
  body += 4;
  int body_len = total - (int)(body - resp);

  if (buf_size == 0) return body_len;
  int to_copy = body_len < buf_size ? body_len : buf_size;
  memcpy(buf, body, to_copy);
  return to_copy;
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
