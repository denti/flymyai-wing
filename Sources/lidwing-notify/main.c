/*
 * lidwing-notify — the hook helper a coding agent execs when it needs the user.
 *
 * It runs inside somebody else's tool, on their critical path, possibly hundreds of times a
 * session. So the entire contract is:
 *
 *   * a static C binary of a few kilobytes — never a shell script, never node, never python,
 *     which would each cost 200-800 ms of interpreter startup on every notification;
 *   * a non-blocking connect with a 100 ms budget, so a missing or wedged listener costs the
 *     user's agent almost nothing;
 *   * `return 0` unconditionally. Exit code 2 is a *blocking* error in Claude Code and would
 *     stall the agent it is meant to be helping. There is no failure mode of this program
 *     that is worth interrupting somebody's work for;
 *   * `execv` the chained command if one was configured, so occupying Codex's single `notify`
 *     slot does not take a feature away from whoever was there first.
 *
 * The message it sends is advisory. Invariant I8: nothing arriving on that socket can arm
 * anything. Its only permitted effects are a sound, a notification and an indicator.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <sys/select.h>

#define BUDGET_MS      100
#define MAX_BODY       200      /* bodies are truncated: this is untrusted text */
#define MAX_STDIN      4096

static void socket_path(char *out, size_t size) {
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') { out[0] = '\0'; return; }
    snprintf(out, size, "%s/Library/Application Support/Lidwing/notify.sock", home);
}

/* Connect with a hard time budget. Never blocks the caller for longer than BUDGET_MS. */
static int connect_with_budget(const char *path) {
    struct sockaddr_un address;
    int fd, flags, result;
    fd_set writable;
    struct timeval timeout;

    if (path[0] == '\0') return -1;
    if (strlen(path) >= sizeof(address.sun_path)) return -1;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return -1; }

    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);

    result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    if (result == 0) return fd;
    if (errno != EINPROGRESS) { close(fd); return -1; }

    FD_ZERO(&writable);
    FD_SET(fd, &writable);
    timeout.tv_sec = 0;
    timeout.tv_usec = BUDGET_MS * 1000;
    if (select(fd + 1, NULL, &writable, NULL, &timeout) <= 0) { close(fd); return -1; }

    {
        int error = 0;
        socklen_t length = sizeof(error);
        if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0 || error != 0) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

/* One JSON line. The receiver treats every byte of it as untrusted text: it is never rendered
 * as markup, never executed, and never used to decide anything privileged. */
static void send_message(int fd, const char *source, const char *body) {
    char line[MAX_BODY + 128];
    char safe[MAX_BODY + 1];
    size_t i, n;

    n = 0;
    for (i = 0; body != NULL && body[i] != '\0' && n < MAX_BODY; i++) {
        unsigned char c = (unsigned char)body[i];
        /* Strip anything that could break the line framing or a terminal. */
        if (c == '"' || c == '\\' || c < 0x20 || c == 0x7f) continue;
        safe[n++] = (char)c;
    }
    safe[n] = '\0';

    snprintf(line, sizeof(line), "{\"v\":1,\"src\":\"%s\",\"body\":\"%s\"}\n", source, safe);
    /* Best effort. A short write, a full buffer or a vanished peer are all fine. */
    (void)!write(fd, line, strlen(line));
}

int main(int argc, char **argv) {
    char path[512];
    char stdin_buffer[MAX_STDIN];
    const char *source = "hook";
    const char *body = NULL;
    int chain_start = 0;
    int fd, i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--codex") == 0) {
            source = "codex";
        } else if (strcmp(argv[i], "--claude") == 0) {
            source = "claude";
        } else if (strcmp(argv[i], "--chain") == 0) {
            /* Everything after --chain is the command we displaced, verbatim. */
            chain_start = i + 1;
            break;
        } else if (body == NULL) {
            body = argv[i];
        }
    }

    /* Claude Code delivers the payload on stdin; Codex passes it as argv[1]. Reading stdin
     * must never block: if nothing is there, we move on. */
    if (body == NULL) {
        ssize_t got;
        int flags = fcntl(STDIN_FILENO, F_GETFL, 0);
        if (flags >= 0) (void)fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK);
        got = read(STDIN_FILENO, stdin_buffer, sizeof(stdin_buffer) - 1);
        if (got > 0) {
            stdin_buffer[got] = '\0';
            body = stdin_buffer;
        }
    }

    socket_path(path, sizeof(path));
    fd = connect_with_budget(path);
    if (fd >= 0) {
        send_message(fd, source, body);
        close(fd);
    }

    /* Hand over to whoever owned this hook before us. If the exec fails there is still
     * nothing worth failing the caller for. */
    if (chain_start > 0 && chain_start < argc) {
        execv(argv[chain_start], &argv[chain_start]);
    }

    return 0;
}
