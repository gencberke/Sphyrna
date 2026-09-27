#include "CLoomPOSIX.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>
#include <uuid/uuid.h>

static int private_fd(int fd) {
    int result = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    int saved = errno;
    close(fd);
    errno = saved;
    return result;
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

pid_t loom_spawn_pty(const char *path, char *const argv[], char *const envp[],
                     const char *cwd, unsigned short rows, unsigned short cols,
                     int *master_fd) {
    if (master_fd == NULL) { errno = EINVAL; return -1; }
    *master_fd = -1;
    if (path == NULL || argv == NULL || argv[0] == NULL || envp == NULL) {
        errno = EINVAL; return -1;
    }
    int master = -1, slave = -1, errors[2] = {-1, -1};
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) < 0) { return -1; }
    long system_max = sysconf(_SC_OPEN_MAX);
    rlim_t upper = limit.rlim_max;
    if (upper == RLIM_INFINITY) {
        int kernel_max = 0;
        size_t length = sizeof(kernel_max);
        if (sysctlbyname("kern.maxfilesperproc", &kernel_max, &length, NULL, 0) < 0) {
            return -1;
        }
        upper = (rlim_t)kernel_max;
    }
    if (system_max > 0 && (rlim_t)system_max > upper) { upper = (rlim_t)system_max; }
    if (upper > INT_MAX) { errno = EOVERFLOW; return -1; }
    const int max_fd = (int)upper;
    struct winsize size = { .ws_row = rows, .ws_col = cols };
    if (openpty(&master, &slave, NULL, NULL, &size) < 0) { return -1; }
    master = private_fd(master);
    if (master < 0) { goto fail; }
    slave = private_fd(slave);
    if (slave < 0) { goto fail; }
    int master_flags = fcntl(master, F_GETFL);
    if (master_flags < 0 || fcntl(master, F_SETFL, master_flags | O_NONBLOCK) < 0) { goto fail; }
    if (pipe(errors) < 0) { goto fail; }
    errors[0] = private_fd(errors[0]);
    if (errors[0] < 0) { goto fail; }
    errors[1] = private_fd(errors[1]);
    if (errors[1] < 0) { goto fail; }

    sigset_t all_signals, old_signals, empty_signals;
    sigfillset(&all_signals);
    sigemptyset(&empty_signals);
    struct sigaction default_action;
    memset(&default_action, 0, sizeof(default_action));
    default_action.sa_handler = SIG_DFL;
    sigemptyset(&default_action.sa_mask);
    int mask_error = pthread_sigmask(SIG_SETMASK, &all_signals, &old_signals);
    if (mask_error != 0) { errno = mask_error; goto fail; }
    pid_t pid = fork();
    int fork_error = errno;
    if (pid == 0) {
        /* No allocation, locks, Swift runtime, or stdio after fork. */
        for (int sig = 1; sig < NSIG; ++sig) {
            if (sig == SIGKILL || sig == SIGSTOP) { continue; }
            if (sigaction(sig, &default_action, NULL) < 0) { child_failure(errors[1], errno); }
        }
        if (setsid() < 0) { child_failure(errors[1], errno); }
        if (ioctl(slave, TIOCSCTTY, 0) < 0) { child_failure(errors[1], errno); }
        for (int fd = 0; fd < 3; ++fd) {
            if (dup2(slave, fd) < 0) { child_failure(errors[1], errno); }
        }
        for (int fd = 3; fd < max_fd; ++fd) {
            if (fd != errors[1]) { close(fd); }
        }
        if (cwd != NULL && chdir(cwd) < 0) { child_failure(errors[1], errno); }
        if (sigprocmask(SIG_SETMASK, &empty_signals, NULL) < 0) { child_failure(errors[1], errno); }
        execve(path, argv, envp);
        child_failure(errors[1], errno);
    }
    (void)pthread_sigmask(SIG_SETMASK, &old_signals, NULL);
    if (pid < 0) { errno = fork_error; goto fail; }
    close(slave); slave = -1;
    close(errors[1]); errors[1] = -1;
    int child_error = 0;
    size_t received = 0;
    while (received < sizeof(child_error)) {
        ssize_t n = read(errors[0], (char *)&child_error + received, sizeof(child_error) - received);
        if (n > 0) { received += (size_t)n; }
        else if (n == 0) { break; }
        else if (errno != EINTR) { child_error = errno; received = sizeof(child_error); break; }
    }
    close(errors[0]); errors[0] = -1;
    if (received != 0) {
        if (received != sizeof(child_error)) { child_error = EIO; }
        /* Also handles an unexpected transport failure without leaving a child. */
        (void)kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        errno = child_error;
        goto fail;
    }
    *master_fd = master;
    return pid;
fail: {
        int saved = errno;
        if (master >= 0) { close(master); }
        if (slave >= 0) { close(slave); }
        if (errors[0] >= 0) { close(errors[0]); }
        if (errors[1] >= 0) { close(errors[1]); }
        errno = saved;
        return -1;
    }
}

int loom_processes(loom_process_info **processes, size_t *count) {
    if (processes == NULL || count == NULL) { errno = EINVAL; return -1; }
    *processes = NULL; *count = 0;
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    struct kinfo_proc *raw = NULL;
    size_t bytes = 0;
    for (int attempt = 0; attempt < 8; ++attempt) {
        if (sysctl(mib, 4, NULL, &bytes, NULL, 0) < 0) { return -1; }
        if (bytes == 0) { return 0; }
        if (bytes > SIZE_MAX - 32 * sizeof(*raw)) { errno = EOVERFLOW; return -1; }
        bytes += 32 * sizeof(*raw);
        raw = malloc(bytes);
        if (raw == NULL) { return -1; }
        if (sysctl(mib, 4, raw, &bytes, NULL, 0) == 0) { break; }
        int saved = errno;
        free(raw); raw = NULL;
        if (saved != ENOMEM) { errno = saved; return -1; }
    }
    if (raw == NULL) { errno = EAGAIN; return -1; }
    size_t length = bytes / sizeof(*raw);
    if (length == 0) { free(raw); return 0; }
    loom_process_info *result = calloc(length, sizeof(*result));
    if (result == NULL) { free(raw); return -1; }
    for (size_t i = 0; i < length; ++i) {
        result[i].pid = raw[i].kp_proc.p_pid;
        result[i].ppid = raw[i].kp_eproc.e_ppid;
        result[i].pgid = raw[i].kp_eproc.e_pgid;
        result[i].sid = result[i].pid > 0 ? getsid(result[i].pid) : -1;
        result[i].uid = raw[i].kp_eproc.e_ucred.cr_uid;
        result[i].status = raw[i].kp_proc.p_stat;
        result[i].start_sec = raw[i].kp_proc.p_starttime.tv_sec;
        result[i].start_usec = raw[i].kp_proc.p_starttime.tv_usec;
    }
    free(raw);
    *processes = result; *count = length;
    return 0;
}

void loom_free_processes(loom_process_info *processes) { free(processes); }

int loom_process_path(pid_t pid, char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) { errno = EINVAL; return -1; }
    buffer[0] = '\0';
    if (pid <= 0) { errno = EINVAL; return -1; }
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    errno = 0;
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
        if (errno == 0) { errno = EIO; }
        return -1;
    }
    size_t length = strnlen(path, sizeof(path));
    if (length == sizeof(path)) { errno = EIO; return -1; }
    if (length >= capacity) { errno = ERANGE; return -1; }
    memcpy(buffer, path, length + 1);
    return 0;
}

int loom_physical_footprint(pid_t pid, uint64_t *bytes) {
    if (bytes == NULL) { errno = EINVAL; return -1; }
    *bytes = 0;
    if (pid <= 0) { errno = EINVAL; return -1; }
    struct rusage_info_v0 usage = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0, (rusage_info_t *)&usage) < 0) {
        return -1;
    }
    *bytes = usage.ri_phys_footprint;
    return 0;
}

/* Private ABI verified against Apple's published XNU sources on 2026-09-27:
 * https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h
 *   PROC_PIDCOALITIONINFO = 20; two IDs followed by three reserved uint64_t's.
 * https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/coalition.h
 *   COALITION_NUM_TYPES = 2; COALITION_TYPE_RESOURCE = 0.
 * https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/proc_info.c
 *   proc_pidcoalitioninfo zeroes the structure before filling coalition_id;
 *   proc_pidinfo returns sizeof(struct proc_pidcoalitioninfo).
 * The public SDK omits this flavor. Keep its layout private and fail closed
 * on a changed reply rather than guessing how an unknown layout maps to IDs.
 */
int loom_resource_coalition(pid_t pid, uint64_t *coalition_id) {
    if (coalition_id == NULL) { errno = EINVAL; return -1; }
    *coalition_id = 0;
    if (pid <= 0) { errno = EINVAL; return -1; }
    struct {
        uint64_t ids[2];
        uint64_t reserved[3];
    } info = {0};
    _Static_assert(sizeof(info) == 40, "Unexpected coalition ABI layout");
    const int coalition_flavor = 20;
    errno = 0;
    int received = proc_pidinfo(pid, coalition_flavor, 0, &info, sizeof(info));
    if (received <= 0) {
        if (errno == 0) { errno = ENOTSUP; }
        return -1;
    }
    if (received != sizeof(info) || info.ids[0] == 0 ||
        info.reserved[0] != 0 || info.reserved[1] != 0 || info.reserved[2] != 0) {
        errno = ENOTSUP;
        return -1;
    }
    *coalition_id = info.ids[0];
    return 0;
}

int loom_boot_session_uuid(char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) { errno = EINVAL; return -1; }
    buffer[0] = '\0';
    uuid_string_t raw = {0};
    if (capacity < sizeof(raw)) { errno = ERANGE; return -1; }
    size_t length = sizeof(raw);
    if (sysctlbyname("kern.bootsessionuuid", raw, &length, NULL, 0) < 0) {
        return -1;
    }
    uuid_t parsed;
    if (length != sizeof(raw) || raw[sizeof(raw) - 1] != '\0' ||
        strnlen(raw, sizeof(raw)) != sizeof(raw) - 1 ||
        uuid_parse(raw, parsed) != 0 || uuid_is_null(parsed)) {
        errno = ENOTSUP;
        return -1;
    }
    uuid_unparse_lower(parsed, buffer);
    return 0;
}

static int read_environment_value(pid_t pid, const char *name,
                                  char *buffer, size_t capacity) {
    if (buffer == NULL || capacity == 0) { errno = EINVAL; return -1; }
    buffer[0] = '\0';
    if (pid <= 0 || name == NULL || name[0] == '\0' || strchr(name, '=') != NULL) {
        errno = EINVAL; return -1;
    }
    int argmax = 0;
    size_t size = sizeof(argmax);
    int max_mib[] = { CTL_KERN, KERN_ARGMAX };
    if (sysctl(max_mib, 2, &argmax, &size, NULL, 0) < 0) { return -1; }
    if (argmax <= (int)sizeof(int)) { errno = EIO; return -1; }
    char *data = malloc((size_t)argmax);
    if (data == NULL) { return -1; }
    int mib[] = { CTL_KERN, KERN_PROCARGS2, pid };
    size = (size_t)argmax;
    if (sysctl(mib, 3, data, &size, NULL, 0) < 0) {
        int saved = errno; free(data); errno = saved; return -1;
    }
    int result = -1, saved = EIO, argc = 0;
    if (size < sizeof(argc)) { goto done; }
    memcpy(&argc, data, sizeof(argc));
    if (argc < 0) { goto done; }
    char *cursor = data + sizeof(argc), *end = data + size;
    char *nul = memchr(cursor, '\0', (size_t)(end - cursor));
    if (nul == NULL) { goto done; }
    cursor = nul + 1;
    while (cursor < end && *cursor == '\0') { ++cursor; }
    for (int i = 0; i < argc; ++i) {
        nul = memchr(cursor, '\0', (size_t)(end - cursor));
        if (nul == NULL) { goto done; }
        cursor = nul + 1;
    }
    while (cursor < end && *cursor != '\0') {
        nul = memchr(cursor, '\0', (size_t)(end - cursor));
        if (nul == NULL) { goto done; }
        size_t name_length = strlen(name);
        size_t length = (size_t)(nul - cursor);
        if (length > name_length && cursor[name_length] == '=' &&
            memcmp(cursor, name, name_length) == 0) {
            size_t value_length = length - name_length - 1;
            if (value_length >= capacity) { saved = ERANGE; goto done; }
            memcpy(buffer, cursor + name_length + 1, value_length);
            buffer[value_length] = '\0';
            result = 1; goto done;
        }
        cursor = nul + 1;
    }
    result = 0;
done:
    free(data);
    if (result < 0) { errno = saved; }
    return result;
}

int loom_read_run_id(pid_t pid, char *buffer, size_t capacity) {
    return read_environment_value(pid, "LOOM_RUN_ID", buffer, capacity);
}

int loom_read_managed_run_id(pid_t pid, char *buffer, size_t capacity) {
    return read_environment_value(pid, "LOOM_MANAGED_RUN_ID", buffer, capacity);
}

int loom_signal_if_matches(pid_t pid, int64_t start_sec, int64_t start_usec,
                           int signal_number) {
    if (pid <= 1) { errno = EINVAL; return -1; }
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc process;
    size_t size = sizeof(process);
    if (sysctl(mib, 4, &process, &size, NULL, 0) < 0) { return -1; }
    if (size != sizeof(process) || process.kp_proc.p_pid != pid ||
        process.kp_proc.p_starttime.tv_sec != start_sec ||
        process.kp_proc.p_starttime.tv_usec != start_usec) {
        errno = ESRCH; return -1;
    }
    if (process.kp_eproc.e_ucred.cr_uid != getuid()) {
        errno = EPERM; return -1;
    }
    return kill(pid, signal_number);
}
