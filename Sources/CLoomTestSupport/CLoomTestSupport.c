#include "CLoomTestSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

struct child_message { pid_t pid; int error; };

static void report(int fd, pid_t pid, int error) {
    struct child_message message = { pid, error };
    const char *cursor = (const char *)&message;
    size_t remaining = sizeof(message);
    while (remaining) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) _exit(125);
        cursor += count;
        remaining -= (size_t)count;
    }
}

static void fail(int fd) {
    int saved_errno = errno;
    report(fd, 0, saved_errno);
    _exit(126);
}

int loom_fixture_spawn(const char *path, const char *const argv[],
                       int escape_session, pid_t *descendant_pid) {
    int channel[2];
    if (pipe(channel) < 0) return errno;
    if (fcntl(channel[1], F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno;
        close(channel[0]); close(channel[1]);
        return error;
    }
    // Prepare the signal disposition before fork; the child uses only POSIX calls.
    struct sigaction ignored = {0};
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    pid_t child = fork();
    if (child < 0) {
        int error = errno;
        close(channel[0]); close(channel[1]);
        return error;
    }
    if (child == 0) {
        close(channel[0]);
        alarm(28);
        if (sigaction(SIGHUP, &ignored, NULL) < 0) fail(channel[1]);
        if (escape_session) {
            if (setsid() < 0) fail(channel[1]);
            pid_t detached = fork();
            if (detached < 0) fail(channel[1]);
            if (detached > 0) {
                report(channel[1], detached, 0);
                _exit(0);
            }
            // Timers are not inherited across fork.
            alarm(28);
        } else {
            if (setpgid(0, 0) < 0) fail(channel[1]);
            report(channel[1], getpid(), 0);
        }
        execv(path, (char *const *)argv);
        fail(channel[1]);
    }
    close(channel[1]);
    int error = 0;
    *descendant_pid = 0;
    // CLOEXEC makes EOF an exec handshake; errors are reported before exit.
    for (;;) {
        struct child_message message;
        char *cursor = (char *)&message;
        size_t remaining = sizeof(message);
        while (remaining) {
            ssize_t count = read(channel[0], cursor, remaining);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) { error = errno; break; }
            if (count == 0) break;
            cursor += count;
            remaining -= (size_t)count;
        }
        if (remaining) {
            if (remaining != sizeof(message) && !error) error = EIO;
            break;
        }
        if (message.error) error = message.error;
        if (message.pid) *descendant_pid = message.pid;
    }
    close(channel[0]);
    if (escape_session || error) {
        while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    }
    return error ? error : (*descendant_pid > 0 ? 0 : EIO);
}

void loom_fixture_ignore_termination(void) {
    struct sigaction ignored = {0};
    sigemptyset(&ignored.sa_mask);
    ignored.sa_handler = SIG_IGN;
    sigaction(SIGHUP, &ignored, NULL);
    sigaction(SIGTERM, &ignored, NULL);
}

void loom_fixture_wait(int stubborn) {
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = SIG_DFL;
    sigaction(SIGALRM, &action, NULL);
    if (stubborn) loom_fixture_ignore_termination();
    unsigned int remaining = alarm(0);
    alarm(remaining && remaining < 29 ? remaining : 29);
    for (;;) pause();
}
