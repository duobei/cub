#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>

static int health_fd = -1;
static time_t start_time = 0;

// Start a minimal TCP health server on the given port.
// Returns 0 on success, -1 on error.
int cub_health_start(int port) {
    if (health_fd >= 0) return 0; // already started

    start_time = time(NULL);

    health_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (health_fd < 0) return -1;

    // Allow port reuse
    int opt = 1;
    setsockopt(health_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Set non-blocking
    int flags = fcntl(health_fd, F_GETFL, 0);
    fcntl(health_fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(health_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(health_fd);
        health_fd = -1;
        return -1;
    }

    if (listen(health_fd, 5) < 0) {
        close(health_fd);
        health_fd = -1;
        return -1;
    }

    return 0;
}

// Accept and respond to one pending health check request.
// session_count is passed in from MoonBit.
// Returns 1 if a request was handled, 0 if no pending request, -1 on error.
int cub_health_poll(int session_count) {
    if (health_fd < 0) return -1;

    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);
    int client_fd = accept(health_fd, (struct sockaddr *)&client_addr, &client_len);
    if (client_fd < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }

    // Read the request (we don't really care about the content)
    char req_buf[1024];
    ssize_t ignore_read = read(client_fd, req_buf, sizeof(req_buf));
    (void)ignore_read;

    // Build JSON response
    time_t now = time(NULL);
    long uptime = (long)(now - start_time);

    char body[256];
    snprintf(body, sizeof(body),
             "{\"status\":\"ok\",\"uptime\":%ld,\"sessions\":%d}",
             uptime, session_count);

    char response[512];
    snprintf(response, sizeof(response),
             "HTTP/1.1 200 OK\r\n"
             "Content-Type: application/json\r\n"
             "Content-Length: %lu\r\n"
             "Connection: close\r\n"
             "\r\n"
             "%s",
             strlen(body), body);

    ssize_t ignore_write = write(client_fd, response, strlen(response));
    (void)ignore_write;
    close(client_fd);

    return 1;
}

// Stop the health server.
void cub_health_stop(void) {
    if (health_fd >= 0) {
        close(health_fd);
        health_fd = -1;
    }
}
