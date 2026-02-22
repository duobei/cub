#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/wait.h>
#include <fcntl.h>

// Maximum number of concurrent MCP processes
#define MAX_PROCESSES 16

typedef struct {
    pid_t pid;
    int stdin_fd;   // write end (parent writes to child stdin)
    int stdout_fd;  // read end (parent reads from child stdout)
    int active;
} McpProcess;

static McpProcess processes[MAX_PROCESSES];
static int initialized = 0;

static void ensure_init(void) {
    if (!initialized) {
        memset(processes, 0, sizeof(processes));
        initialized = 1;
    }
}

// Spawn a child process with bidirectional pipes.
// command and args are null-terminated C strings.
// env_keys and env_vals are null-terminated, newline-separated lists.
// Returns process slot index (>= 0) or -1 on error.
int cub_mcp_spawn(const char *command, const char *args_str,
                   const char *env_keys, const char *env_vals) {
    ensure_init();

    // Find free slot
    int slot = -1;
    for (int i = 0; i < MAX_PROCESSES; i++) {
        if (!processes[i].active) {
            slot = i;
            break;
        }
    }
    if (slot < 0) return -1;

    // Create pipes: parent_to_child and child_to_parent
    int p2c[2], c2p[2];
    if (pipe(p2c) < 0) return -1;
    if (pipe(c2p) < 0) {
        close(p2c[0]); close(p2c[1]);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(p2c[0]); close(p2c[1]);
        close(c2p[0]); close(c2p[1]);
        return -1;
    }

    if (pid == 0) {
        // Child process
        close(p2c[1]); // close write end of parent-to-child
        close(c2p[0]); // close read end of child-to-parent

        dup2(p2c[0], STDIN_FILENO);
        dup2(c2p[1], STDOUT_FILENO);
        close(p2c[0]);
        close(c2p[1]);

        // Parse environment variables (newline-separated)
        if (env_keys && env_vals && strlen(env_keys) > 0) {
            char *keys_copy = strdup(env_keys);
            char *vals_copy = strdup(env_vals);
            char *key_tok = strtok(keys_copy, "\n");
            char *val_tok = strtok(vals_copy, "\n");
            while (key_tok && val_tok) {
                setenv(key_tok, val_tok, 1);
                key_tok = strtok(NULL, "\n");
                val_tok = strtok(NULL, "\n");
            }
            free(keys_copy);
            free(vals_copy);
        }

        // Parse args (newline-separated)
        char *argv[64];
        int argc = 0;
        argv[argc++] = (char *)command;

        if (args_str && strlen(args_str) > 0) {
            char *args_copy = strdup(args_str);
            char *tok = strtok(args_copy, "\n");
            while (tok && argc < 63) {
                argv[argc++] = tok;
                tok = strtok(NULL, "\n");
            }
            // Note: args_copy is leaked intentionally (exec replaces process)
        }
        argv[argc] = NULL;

        execvp(command, argv);
        _exit(127); // exec failed
    }

    // Parent process
    close(p2c[0]); // close read end
    close(c2p[1]); // close write end

    // Set stdout_fd to non-blocking
    int flags = fcntl(c2p[0], F_GETFL, 0);
    fcntl(c2p[0], F_SETFL, flags | O_NONBLOCK);

    processes[slot].pid = pid;
    processes[slot].stdin_fd = p2c[1];
    processes[slot].stdout_fd = c2p[0];
    processes[slot].active = 1;

    return slot;
}

// Write data to the child's stdin. Returns bytes written or -1.
int cub_mcp_write(int slot, const char *data, int len) {
    ensure_init();
    if (slot < 0 || slot >= MAX_PROCESSES || !processes[slot].active) return -1;

    int total = 0;
    while (total < len) {
        int n = write(processes[slot].stdin_fd, data + total, len - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            return total > 0 ? total : -1;
        }
        total += n;
    }
    return total;
}

// Read data from the child's stdout into buf. Returns bytes read, 0 if no data, -1 on error.
int cub_mcp_read(int slot, char *buf, int buf_size) {
    ensure_init();
    if (slot < 0 || slot >= MAX_PROCESSES || !processes[slot].active) return -1;

    int n = read(processes[slot].stdout_fd, buf, buf_size);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
        return -1;
    }
    return n;
}

// Kill the child process and clean up.
int cub_mcp_kill(int slot) {
    ensure_init();
    if (slot < 0 || slot >= MAX_PROCESSES || !processes[slot].active) return -1;

    kill(processes[slot].pid, SIGTERM);

    // Non-blocking wait
    int status;
    pid_t ret = waitpid(processes[slot].pid, &status, WNOHANG);
    if (ret == 0) {
        // Process hasn't exited yet, give it a moment
        usleep(100000); // 100ms
        ret = waitpid(processes[slot].pid, &status, WNOHANG);
        if (ret == 0) {
            kill(processes[slot].pid, SIGKILL);
            waitpid(processes[slot].pid, &status, 0);
        }
    }

    close(processes[slot].stdin_fd);
    close(processes[slot].stdout_fd);
    processes[slot].active = 0;

    return 0;
}

// Check if process is still alive. Returns 1 if alive, 0 if dead.
int cub_mcp_alive(int slot) {
    ensure_init();
    if (slot < 0 || slot >= MAX_PROCESSES || !processes[slot].active) return 0;

    int status;
    pid_t ret = waitpid(processes[slot].pid, &status, WNOHANG);
    if (ret == 0) return 1;  // still running
    if (ret == processes[slot].pid) {
        // Process exited
        processes[slot].active = 0;
        close(processes[slot].stdin_fd);
        close(processes[slot].stdout_fd);
        return 0;
    }
    return 1; // assume alive on error
}
