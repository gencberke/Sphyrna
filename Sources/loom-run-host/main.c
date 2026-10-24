/* LoomRunHost: launched by LaunchServices so it starts as the only member of a
 * fresh resource coalition. Every process it starts for Loom, and every process
 * those fork (including setsid/double-fork escapes), stays in that coalition.
 * Loom owns the run; this host only spawns, reports exit statuses, and, when
 * Loom disappears without an orderly EXIT, stops the forked work in its own
 * coalition before exiting. It never signals launchd-spawned members. */
#include "CLoomPOSIX.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum {
    FRAME_HELLO = 1, FRAME_SPAWN = 2, FRAME_SPAWNED = 3, FRAME_EXITED = 4, FRAME_EXIT = 5,
};
enum { SPAWN_PTY = 1, SPAWN_STDIO = 2 };

static int child_signal_pipe[2] = { -1, -1 };

static void child_signal(int signal_number) {
    (void)signal_number;
    int saved = errno;
    char byte = 1;
    (void)write(child_signal_pipe[1], &byte, 1);
    errno = saved;
}

static void child_failure(int fd, int error) {
    const char *bytes = (const char *)&error;
    size_t left = sizeof(error);
    while (left > 0) {
        ssize_t n = write(fd, bytes, left);
        if (n > 0) { bytes += n; left -= (size_t)n; }
        else if (n < 0 && errno == EINTR) { continue; }
        else { break; }
    }
    _exit(127);
}

static void put_u32(uint8_t *out, uint32_t value) {
    out[0] = (uint8_t)value; out[1] = (uint8_t)(value >> 8);
    out[2] = (uint8_t)(value >> 16); out[3] = (uint8_t)(value >> 24);
}

static uint32_t get_u32(const uint8_t *in) {
    return (uint32_t)in[0] | ((uint32_t)in[1] << 8) | ((uint32_t)in[2] << 16) | ((uint32_t)in[3] << 24);
}

static int send_spawned(int socket_fd, uint32_t request, int32_t pid, int32_t error) {
    uint8_t payload[12];
    put_u32(payload, request);
    put_u32(payload + 4, (uint32_t)pid);
    put_u32(payload + 8, (uint32_t)error);
    return loom_send_frame(socket_fd, FRAME_SPAWNED, payload, sizeof(payload), NULL, 0);
}

/* Payload: u32 request, u8 mode, u32 argc, u32 envc, then NUL-terminated
 * path, cwd (empty keeps the host's), argv[argc], envp[envc]. */
static pid_t spawn_request(const uint8_t *payload, uint32_t length, const int *fds, int fd_count,
                           uint32_t *request, int *error) {
    *error = EPROTO;
    if (length < 13) { return -1; }
    *request = get_u32(payload);
    uint8_t mode = payload[4];
    uint32_t argc = get_u32(payload + 5), envc = get_u32(payload + 9);
    if ((mode == SPAWN_PTY && fd_count != 1) || (mode == SPAWN_STDIO && fd_count != 3) ||
        (mode != SPAWN_PTY && mode != SPAWN_STDIO) || argc == 0 || argc > 4096 || envc > 65536) {
        return -1;
    }
    size_t strings = 2 + (size_t)argc + (size_t)envc;
    const char **items = calloc(strings + 2, sizeof(char *));
    if (items == NULL) { *error = ENOMEM; return -1; }
    const char *cursor = (const char *)payload + 13, *end = (const char *)payload + length;
    for (size_t i = 0; i < strings; ++i) {
        const char *nul = memchr(cursor, '\0', (size_t)(end - cursor));
        if (nul == NULL) { free(items); return -1; }
        items[i] = cursor;
        cursor = nul + 1;
    }
    if (cursor != end) { free(items); return -1; }
    const char *path = items[0], *cwd = items[1];
    /* argv and envp each need a NULL terminator: copy into separate arrays. */
    char **argv = calloc((size_t)argc + 1, sizeof(char *));
    char **envp = calloc((size_t)envc + 1, sizeof(char *));
    if (argv == NULL || envp == NULL) { free(items); free(argv); free(envp); *error = ENOMEM; return -1; }
    for (uint32_t i = 0; i < argc; ++i) { argv[i] = (char *)items[2 + i]; }
    for (uint32_t i = 0; i < envc; ++i) { envp[i] = (char *)items[2 + argc + i]; }

    int errors[2] = { -1, -1 };
    pid_t pid = -1;
    if (pipe(errors) < 0) { *error = errno; goto done; }
    (void)fcntl(errors[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(errors[1], F_SETFD, FD_CLOEXEC);
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    sigset_t all_signals, old_signals, empty_signals;
    sigfillset(&all_signals);
    sigemptyset(&empty_signals);
    pthread_sigmask(SIG_SETMASK, &all_signals, &old_signals);
    pid = fork();
    int fork_error = errno;
    if (pid == 0) {
        /* Async-signal-safe calls only. */
        for (int sig = 1; sig < NSIG; ++sig) {
            if (sig == SIGKILL || sig == SIGSTOP) { continue; }
            if (sigaction(sig, &default_action, NULL) < 0) { child_failure(errors[1], errno); }
        }
        if (setsid() < 0) { child_failure(errors[1], errno); }
        if (mode == SPAWN_PTY) {
            if (ioctl(fds[0], TIOCSCTTY, 0) < 0) { child_failure(errors[1], errno); }
            for (int fd = 0; fd < 3; ++fd) {
                if (dup2(fds[0], fd) < 0) { child_failure(errors[1], errno); }
            }
        } else {
            /* Move sources above 2 first so dup2 cannot clobber a later source. */
            int moved[3];
            for (int fd = 0; fd < 3; ++fd) {
                moved[fd] = fcntl(fds[fd], F_DUPFD_CLOEXEC, 3);
                if (moved[fd] < 0) { child_failure(errors[1], errno); }
            }
            for (int fd = 0; fd < 3; ++fd) {
                if (dup2(moved[fd], fd) < 0) { child_failure(errors[1], errno); }
            }
        }
        if (cwd[0] != '\0' && chdir(cwd) < 0) { child_failure(errors[1], errno); }
        if (sigprocmask(SIG_SETMASK, &empty_signals, NULL) < 0) { child_failure(errors[1], errno); }
        /* Every host descriptor is CLOEXEC, so exec leaves only 0-2 open. */
        execve(path, argv, envp);
        child_failure(errors[1], errno);
    }
    pthread_sigmask(SIG_SETMASK, &old_signals, NULL);
    if (pid < 0) { *error = fork_error; goto done; }
    close(errors[1]); errors[1] = -1;
    int child_error = 0;
    size_t received = 0;
    while (received < sizeof(child_error)) {
        ssize_t n = read(errors[0], (char *)&child_error + received, sizeof(child_error) - received);
        if (n > 0) { received += (size_t)n; }
        else if (n == 0) { break; }
        else if (errno != EINTR) { child_error = errno; received = sizeof(child_error); break; }
    }
    if (received != 0) {
        if (received != sizeof(child_error)) { child_error = EIO; }
        (void)kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        *error = child_error;
        pid = -1;
        goto done;
    }
    *error = 0;
done:
    if (errors[0] >= 0) { close(errors[0]); }
    if (errors[1] >= 0) { close(errors[1]); }
    free(items); free(argv); free(envp);
    return pid;
}

static void report_exits(int socket_fd) {
    for (;;) {
        int status = 0;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid <= 0) {
            if (pid < 0 && errno == EINTR) { continue; }
            return;
        }
        uint8_t payload[8];
        put_u32(payload, (uint32_t)pid);
        put_u32(payload + 4, (uint32_t)status);
        (void)loom_send_frame(socket_fd, FRAME_EXITED, payload, sizeof(payload), NULL, 0);
    }
}

/* Loom disappeared without an orderly EXIT: stop this scope's forked work. */
static void stop_orphaned_scope(void) {
    uint64_t coalition = 0;
    if (loom_resource_coalition(getpid(), &coalition) < 0) { return; }
    loom_scope_member *members = NULL;
    size_t count = 0;
    if (loom_scope_members(coalition, &members, &count) == 0) {
        for (size_t i = 0; i < count; ++i) {
            if (members[i].launchd_spawned || members[i].zombie || members[i].pid == getpid()) { continue; }
            (void)loom_signal_scope_member(members[i].pid, members[i].id_version, coalition, SIGHUP);
        }
        loom_free_scope_members(members);
    }
    struct timespec grace = { 0, 500 * 1000 * 1000 };
    nanosleep(&grace, NULL);
    (void)loom_kill_scope_forked_members(coalition, getpid(), 10.0);
}

/* The host serves only its owner: the listener on the other end of the
 * socket must satisfy the code requirement sealed into this host's own
 * Info.plist (LoomOwnerRequirement) at packaging. Trust is never derived from
 * where the host sits: a genuine host copied into another app keeps its TCC
 * identity, so the owner must be part of what its signature seals. With a
 * stable signing identity the requirement names Loom's certificate; ad-hoc
 * builds can only name Loom's identifier. Returns 1 for the owner. Runs on
 * the checker thread (`peer_is_owner`). */
static int check_peer_is_owner(int socket_fd) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFTypeRef text = bundle ? CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("LoomOwnerRequirement")) : NULL;
    if (text == NULL || CFGetTypeID(text) != CFStringGetTypeID()) { return 0; }
    audit_token_t token;
    socklen_t size = sizeof(token);
    if (getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) < 0 || size != sizeof(token)) { return 0; }
    int verified = 0;
    SecRequirementRef requirement = NULL;
    CFDataRef tokenData = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    CFDictionaryRef attributes = NULL;
    SecCodeRef peer = NULL;
    if (tokenData == NULL) { goto done; }
    if (SecRequirementCreateWithString((CFStringRef)text, kSecCSDefaultFlags, &requirement) != errSecSuccess) { goto done; }
    const void *keys[] = { kSecGuestAttributeAudit };
    const void *values[] = { tokenData };
    attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                    &kCFTypeDictionaryValueCallBacks);
    if (attributes == NULL) { goto done; }
    if (SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &peer) != errSecSuccess) { goto done; }
    verified = SecCodeCheckValidity(peer, kSecCSDefaultFlags, requirement) == errSecSuccess;
done:
    if (peer) { CFRelease(peer); }
    if (attributes) { CFRelease(attributes); }
    if (tokenData) { CFRelease(tokenData); }
    if (requirement) { CFRelease(requirement); }
    return verified;
}

struct owner_check {
    int socket_fd;
    int verified;
};

static void *owner_check_thread(void *argument) {
    struct owner_check *check = argument;
    check->verified = check_peer_is_owner(check->socket_fd);
    return NULL;
}

/* The signature check runs on a thread of its own and the main thread waits
 * for it: Security warns when SecCode calls run on the main thread (FB5-12),
 * and nothing is served before the answer. A thread that cannot be started
 * refuses the peer, as a failed check does. */
static int peer_is_owner(int socket_fd) {
    struct owner_check check = { socket_fd, 0 };
    pthread_t thread;
    if (pthread_create(&thread, NULL, owner_check_thread, &check) != 0) { return 0; }
    if (pthread_join(thread, NULL) != 0) { return 0; }
    return check.verified;
}

static void close_on_exec_all(void) {
    struct rlimit limit;
    int upper = 4096;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0 && limit.rlim_cur != RLIM_INFINITY && limit.rlim_cur < (rlim_t)upper) {
        upper = (int)limit.rlim_cur;
    }
    for (int fd = 3; fd < upper; ++fd) { (void)fcntl(fd, F_SETFD, FD_CLOEXEC); }
}

int main(int argc, char **argv) {
    const char *socket_path = NULL, *token = NULL;
    for (int i = 1; i + 1 < argc; i += 2) {
        if (strcmp(argv[i], "--socket") == 0) { socket_path = argv[i + 1]; }
        else if (strcmp(argv[i], "--token") == 0) { token = argv[i + 1]; }
    }
    if (socket_path == NULL || token == NULL) { return 64; }
    close_on_exec_all();
    signal(SIGPIPE, SIG_IGN);
    if (pipe(child_signal_pipe) < 0) { return 71; }
    for (int i = 0; i < 2; ++i) {
        (void)fcntl(child_signal_pipe[i], F_SETFD, FD_CLOEXEC);
        (void)fcntl(child_signal_pipe[i], F_SETFL, O_NONBLOCK);
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = child_signal;
    action.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigemptyset(&action.sa_mask);
    sigaction(SIGCHLD, &action, NULL);

    int socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_fd < 0) { return 71; }
    (void)fcntl(socket_fd, F_SETFD, FD_CLOEXEC);
    int no_sigpipe = 1;
    (void)setsockopt(socket_fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof(address.sun_path)) { return 64; }
    strncpy(address.sun_path, socket_path, sizeof(address.sun_path) - 1);
    if (connect(socket_fd, (struct sockaddr *)&address, sizeof(address)) < 0) { return 69; }
    if (!peer_is_owner(socket_fd)) { return 77; }
    if (loom_send_frame(socket_fd, FRAME_HELLO, token, (uint32_t)strlen(token), NULL, 0) < 0) { return 69; }

    static uint8_t payload[1 << 20];
    int orderly = 0;
    for (;;) {
        struct pollfd watched[2] = {
            { .fd = socket_fd, .events = POLLIN },
            { .fd = child_signal_pipe[0], .events = POLLIN },
        };
        if (poll(watched, 2, -1) < 0) {
            if (errno == EINTR) { continue; }
            break;
        }
        if (watched[1].revents & POLLIN) {
            char drain[64];
            while (read(child_signal_pipe[0], drain, sizeof(drain)) > 0) {}
            report_exits(socket_fd);
        }
        if (watched[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t type = 0;
            uint32_t length = 0;
            int fds[3];
            int fd_count = 0;
            if (loom_receive_frame(socket_fd, &type, payload, sizeof(payload), &length, fds, &fd_count) < 0) {
                break;
            }
            if (type == FRAME_EXIT) {
                for (int i = 0; i < fd_count; ++i) { close(fds[i]); }
                orderly = 1;
                break;
            }
            if (type == FRAME_SPAWN) {
                uint32_t request = 0;
                int error = 0;
                pid_t pid = spawn_request(payload, length, fds, fd_count, &request, &error);
                for (int i = 0; i < fd_count; ++i) { close(fds[i]); }
                if (send_spawned(socket_fd, request, pid, error) < 0) { break; }
                /* A child that already exited is reported after SPAWNED. */
                report_exits(socket_fd);
                continue;
            }
            for (int i = 0; i < fd_count; ++i) { close(fds[i]); }
            break; /* protocol violation: treat like a lost owner */
        }
    }
    if (!orderly) { stop_orphaned_scope(); }
    close(socket_fd);
    return orderly ? 0 : 75;
}
