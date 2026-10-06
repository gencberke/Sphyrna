#include "CLoomPOSIX.h"

#include <bsm/libbsm.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Private ABI verified against Apple's published XNU sources (xnu-12377.1.9):
 * bsd/sys/proc_info_private.h — PROC_PIDUNIQIDENTIFIERINFO = 17,
 * struct proc_uniqidentifierinfo (56 bytes, static-asserted there as API);
 * PROC_PIDCOALITIONINFO = 20 (see loom_resource_coalition).
 * bsd/kern/kern_fork.c sets p_orig_ppidversion at fork and copies it on exec;
 * bsd/kern/kern_exit.c proc_reparentlocked changes only p_pptr/p_ppid. */
typedef struct {
    uint8_t uuid[16];
    uint64_t unique_id;
    uint64_t parent_unique_id;
    int32_t id_version;
    int32_t original_parent_version;
    uint64_t reserved[2];
} loom_unique_identifier_info;
_Static_assert(sizeof(loom_unique_identifier_info) == 56, "Unexpected uniqidentifier ABI layout");

static int unique_info(pid_t pid, loom_unique_identifier_info *info) {
    memset(info, 0, sizeof(*info));
    errno = 0;
    int received = proc_pidinfo(pid, 17, 0, info, sizeof(*info));
    if (received <= 0) {
        if (errno == 0) { errno = ESRCH; }
        return -1;
    }
    if (received != (int)sizeof(*info) || info->id_version == 0) { errno = ENOTSUP; return -1; }
    return 0;
}

static int launchd_version(int32_t *version) {
    static int32_t cached = 0;
    if (cached != 0) { *version = cached; return 0; }
    loom_unique_identifier_info info;
    if (unique_info(1, &info) < 0) { return -1; }
    cached = info.id_version;
    *version = cached;
    return 0;
}

/* 1 when pid no longer names a live process (gone, or a zombie that can do
 * no more work); 0 when it is alive. Used to decide whether an unreadable
 * process may be skipped: a live unreadable process must fail a scan. */
static int gone_or_zombie(pid_t pid) {
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc process;
    size_t size = sizeof(process);
    if (sysctl(mib, 4, &process, &size, NULL, 0) < 0) { return errno == ESRCH; }
    if (size == 0 || process.kp_proc.p_pid != pid) { return 1; }
    /* A process already in exit can no longer fork or run user code. */
    return process.kp_proc.p_stat == SZOMB || (process.kp_proc.p_flag & P_WEXIT) != 0;
}

int loom_process_lineage(pid_t pid, loom_scope_member *member) {
    if (member == NULL || pid <= 0) { errno = EINVAL; return -1; }
    memset(member, 0, sizeof(*member));
    int32_t launchd = 0;
    if (launchd_version(&launchd) < 0) { return -1; }
    uint64_t coalition = 0;
    if (loom_resource_coalition(pid, &coalition) < 0) {
        if (gone_or_zombie(pid)) { errno = ESRCH; }
        else if (errno == 0 || errno == ESRCH) { errno = EIO; }
        return -1;
    }
    loom_unique_identifier_info info;
    if (unique_info(pid, &info) < 0) {
        if (gone_or_zombie(pid)) { errno = ESRCH; }
        else if (errno != ENOTSUP) { errno = EIO; }
        return -1;
    }
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc process;
    size_t size = sizeof(process);
    if (sysctl(mib, 4, &process, &size, NULL, 0) < 0) { return -1; }
    if (size != sizeof(process) || process.kp_proc.p_pid != pid) { errno = ESRCH; return -1; }
    /* Confirm the pid still names the process whose identifiers were read. */
    loom_unique_identifier_info again;
    if (unique_info(pid, &again) < 0 || again.id_version != info.id_version) { errno = ESRCH; return -1; }
    member->pid = pid;
    member->uid = process.kp_eproc.e_ucred.cr_uid;
    member->zombie = process.kp_proc.p_stat == SZOMB;
    member->id_version = info.id_version;
    member->original_parent_version = info.original_parent_version;
    member->launchd_spawned = info.original_parent_version == launchd;
    member->coalition_id = coalition;
    member->start_sec = process.kp_proc.p_starttime.tv_sec;
    member->start_usec = process.kp_proc.p_starttime.tv_usec;
    return 0;
}

static int all_pids(pid_t **pids, int *count) {
    *pids = NULL; *count = 0;
    for (int attempt = 0; attempt < 8; ++attempt) {
        int needed = proc_listallpids(NULL, 0);
        if (needed <= 0) { if (errno == 0) { errno = EIO; } return -1; }
        int capacity = needed + 256;
        pid_t *buffer = calloc((size_t)capacity, sizeof(pid_t));
        if (buffer == NULL) { return -1; }
        int received = proc_listallpids(buffer, capacity * (int)sizeof(pid_t));
        if (received < 0) { int saved = errno; free(buffer); errno = saved; return -1; }
        if (received < capacity) { *pids = buffer; *count = received; return 0; }
        free(buffer);
    }
    errno = EAGAIN;
    return -1;
}

int loom_scope_members(uint64_t coalition_id, loom_scope_member **members, size_t *count) {
    if (coalition_id == 0) { errno = EINVAL; return -1; }
    return loom_scopes_members(&coalition_id, 1, members, count);
}

static int wanted(uint64_t coalition, const uint64_t *ids, size_t id_count) {
    for (size_t i = 0; i < id_count; ++i) { if (ids[i] == coalition) { return 1; } }
    return 0;
}

int loom_scopes_members(const uint64_t *coalition_ids, size_t id_count,
                        loom_scope_member **members, size_t *count) {
    if (members == NULL || count == NULL || (id_count > 0 && coalition_ids == NULL)) { errno = EINVAL; return -1; }
    *members = NULL; *count = 0;
    if (id_count == 0) { return 0; }
    pid_t *pids = NULL;
    int total = 0;
    if (all_pids(&pids, &total) < 0) { return -1; }
    loom_scope_member *result = calloc((size_t)(total > 0 ? total : 1), sizeof(*result));
    if (result == NULL) { free(pids); return -1; }
    size_t found = 0;
    for (int i = 0; i < total; ++i) {
        if (pids[i] <= 0) { continue; }
        /* A process being created or torn down can be briefly unreadable.
         * Retry; only an exited process or a zombie may be skipped, because a
         * live process that stays unreadable could be a member. */
        uint64_t coalition = 0;
        int read = -1, gone = 0;
        for (int attempt = 0; attempt < 50; ++attempt) {
            read = loom_resource_coalition(pids[i], &coalition);
            if (read == 0 || (gone = gone_or_zombie(pids[i]))) { break; }
            struct timespec pause = { 0, 1000 * 1000 };
            nanosleep(&pause, NULL);
        }
        if (read < 0) {
            if (gone) { continue; }
            free(pids); free(result); errno = EIO; return -1;
        }
        if (!wanted(coalition, coalition_ids, id_count)) { continue; }
        loom_scope_member member;
        int lineage = -1;
        for (int attempt = 0; attempt < 50; ++attempt) {
            lineage = loom_process_lineage(pids[i], &member);
            if (lineage == 0 || errno == ESRCH) { break; }
            struct timespec pause = { 0, 1000 * 1000 };
            nanosleep(&pause, NULL);
        }
        if (lineage < 0) {
            if (errno == ESRCH) { continue; }
            int saved = errno; free(pids); free(result); errno = saved; return -1;
        }
        if (!wanted(member.coalition_id, coalition_ids, id_count)) { continue; }
        result[found++] = member;
    }
    free(pids);
    *members = result; *count = found;
    return 0;
}

void loom_free_scope_members(loom_scope_member *members) { free(members); }

int loom_signal_scope_member(pid_t pid, int32_t id_version, uint64_t coalition_id,
                             int signal_number) {
    if (pid <= 1 || coalition_id == 0) { errno = EINVAL; return -1; }
    loom_scope_member member;
    if (loom_process_lineage(pid, &member) < 0) { errno = ESRCH; return -1; }
    if (member.id_version != id_version || member.coalition_id != coalition_id) { errno = ESRCH; return -1; }
    if (member.uid != getuid()) { errno = EPERM; return -1; }
    return kill(pid, signal_number);
}

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

int loom_kill_scope_forked_members(uint64_t coalition_id, pid_t exclude,
                                   double timeout_seconds) {
    const double deadline = monotonic_seconds() + (timeout_seconds > 0 ? timeout_seconds : 0);
    for (;;) {
        loom_scope_member *members = NULL;
        size_t count = 0;
        if (loom_scope_members(coalition_id, &members, &count) < 0) { return -1; }
        int live = 0;
        /* Freeze first so no member can fork between the scan and the kill. */
        for (size_t i = 0; i < count; ++i) {
            if (members[i].launchd_spawned || members[i].zombie || members[i].pid == exclude) { continue; }
            ++live;
            (void)loom_signal_scope_member(members[i].pid, members[i].id_version, coalition_id, SIGSTOP);
        }
        for (size_t i = 0; i < count; ++i) {
            if (members[i].launchd_spawned || members[i].zombie || members[i].pid == exclude) { continue; }
            (void)loom_signal_scope_member(members[i].pid, members[i].id_version, coalition_id, SIGKILL);
        }
        loom_free_scope_members(members);
        if (live == 0) { return 0; }
        if (monotonic_seconds() >= deadline) { return live; }
        struct timespec pause = { 0, 2 * 1000 * 1000 };
        nanosleep(&pause, NULL);
    }
}

static int write_all_with_fds(int socket_fd, const uint8_t *bytes, size_t length,
                              const int *fds, int fd_count) {
    size_t sent = 0;
    int attach = fd_count > 0;
    while (sent < length) {
        struct iovec vector = { .iov_base = (void *)(bytes + sent), .iov_len = length - sent };
        struct msghdr message;
        memset(&message, 0, sizeof(message));
        message.msg_iov = &vector;
        message.msg_iovlen = 1;
        union {
            struct cmsghdr header;
            char space[CMSG_SPACE(3 * sizeof(int))];
        } control;
        if (attach) {
            memset(&control, 0, sizeof(control));
            message.msg_control = control.space;
            message.msg_controllen = (socklen_t)CMSG_SPACE((size_t)fd_count * sizeof(int));
            struct cmsghdr *header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = SOL_SOCKET;
            header->cmsg_type = SCM_RIGHTS;
            header->cmsg_len = (socklen_t)CMSG_LEN((size_t)fd_count * sizeof(int));
            memcpy(CMSG_DATA(header), fds, (size_t)fd_count * sizeof(int));
        }
        ssize_t written = sendmsg(socket_fd, &message, 0);
        if (written < 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        if (written == 0) { errno = EPIPE; return -1; }
        attach = 0;
        sent += (size_t)written;
    }
    return 0;
}

int loom_send_frame(int socket_fd, uint8_t type, const void *payload, uint32_t length,
                    const int *fds, int fd_count) {
    if (fd_count < 0 || fd_count > 3 || (fd_count > 0 && fds == NULL) ||
        (length > 0 && payload == NULL) || length > (1u << 24)) {
        errno = EINVAL; return -1;
    }
    uint8_t *frame = malloc((size_t)length + 5);
    if (frame == NULL) { return -1; }
    frame[0] = (uint8_t)(length & 0xff);
    frame[1] = (uint8_t)((length >> 8) & 0xff);
    frame[2] = (uint8_t)((length >> 16) & 0xff);
    frame[3] = (uint8_t)((length >> 24) & 0xff);
    frame[4] = type;
    if (length > 0) { memcpy(frame + 5, payload, length); }
    int result = write_all_with_fds(socket_fd, frame, (size_t)length + 5, fds, fd_count);
    int saved = errno;
    free(frame);
    errno = saved;
    return result;
}

/* Reads exactly `length` bytes, collecting any descriptors that arrive. */
static int read_exact(int socket_fd, uint8_t *bytes, size_t length,
                      int *fds, int *fd_count, int *overflow) {
    size_t received = 0;
    while (received < length) {
        struct iovec vector = { .iov_base = bytes + received, .iov_len = length - received };
        union {
            struct cmsghdr header;
            char space[CMSG_SPACE(8 * sizeof(int))];
        } control;
        struct msghdr message;
        memset(&message, 0, sizeof(message));
        message.msg_iov = &vector;
        message.msg_iovlen = 1;
        message.msg_control = control.space;
        message.msg_controllen = sizeof(control.space);
        ssize_t n = recvmsg(socket_fd, &message, 0);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            return -1;
        }
        for (struct cmsghdr *header = CMSG_FIRSTHDR(&message); header != NULL;
             header = CMSG_NXTHDR(&message, header)) {
            if (header->cmsg_level != SOL_SOCKET || header->cmsg_type != SCM_RIGHTS) { continue; }
            size_t carried = (header->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            int *incoming = (int *)CMSG_DATA(header);
            for (size_t i = 0; i < carried; ++i) {
                (void)fcntl(incoming[i], F_SETFD, FD_CLOEXEC);
                if (*fd_count < 3) { fds[(*fd_count)++] = incoming[i]; }
                else { close(incoming[i]); *overflow = 1; }
            }
        }
        if (message.msg_flags & MSG_CTRUNC) { *overflow = 1; }
        if (n == 0) { errno = ECONNRESET; return -1; }
        received += (size_t)n;
    }
    return 0;
}

int loom_receive_frame(int socket_fd, uint8_t *type, void *payload, uint32_t capacity,
                       uint32_t *length, int *fds, int *fd_count) {
    if (type == NULL || length == NULL || fds == NULL || fd_count == NULL ||
        (capacity > 0 && payload == NULL)) {
        errno = EINVAL; return -1;
    }
    *fd_count = 0;
    *length = 0;
    int overflow = 0;
    uint8_t header[5];
    if (read_exact(socket_fd, header, sizeof(header), fds, fd_count, &overflow) < 0) { goto fail; }
    uint32_t size = (uint32_t)header[0] | ((uint32_t)header[1] << 8)
        | ((uint32_t)header[2] << 16) | ((uint32_t)header[3] << 24);
    if (size > capacity) { errno = EMSGSIZE; goto fail; }
    if (size > 0 && read_exact(socket_fd, payload, size, fds, fd_count, &overflow) < 0) { goto fail; }
    if (overflow) { errno = EPROTO; goto fail; }
    *type = header[4];
    *length = size;
    return 0;
fail: {
        int saved = errno;
        for (int i = 0; i < *fd_count; ++i) { close(fds[i]); }
        *fd_count = 0;
        errno = saved;
        return -1;
    }
}

int loom_socket_peer_version(int socket_fd, pid_t *pid, int32_t *pid_version, uid_t *uid) {
    if (pid == NULL || pid_version == NULL || uid == NULL) { errno = EINVAL; return -1; }
    audit_token_t token;
    socklen_t size = sizeof(token);
    if (getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) < 0) { return -1; }
    if (size != sizeof(token)) { errno = EPROTO; return -1; }
    *pid = audit_token_to_pid(token);
    *pid_version = audit_token_to_pidversion(token);
    *uid = audit_token_to_euid(token);
    return 0;
}

int loom_socket_peer(int socket_fd, pid_t *pid, uid_t *uid) {
    if (pid == NULL || uid == NULL) { errno = EINVAL; return -1; }
    pid_t peer = 0;
    socklen_t size = sizeof(peer);
    if (getsockopt(socket_fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) < 0) { return -1; }
    uid_t user = 0;
    gid_t group = 0;
    if (getpeereid(socket_fd, &user, &group) < 0) { return -1; }
    *pid = peer;
    *uid = user;
    return 0;
}
