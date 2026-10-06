#ifndef CLOOM_POSIX_H
#define CLOOM_POSIX_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    pid_t pid;
    pid_t ppid;
    pid_t pgid;
    pid_t sid; /* -1 when the process exited or its session is inaccessible. */
    uid_t uid;
    int status; /* Darwin process status, including SZOMB. */
    int64_t start_sec;
    int64_t start_usec;
} loom_process_info;

/* Spawn path with NULL-terminated argv/envp, cwd (NULL keeps current directory),
 * and terminal dimensions. Returns pid with a nonblocking CLOEXEC master fd.
 * On failure returns -1 with errno, leaves *master_fd = -1, and reaps any child.
 * Successful children belong to a new session with the PTY controlling terminal.
 * Caller owns master_fd and must reap the returned child. */
pid_t loom_spawn_pty(const char *path, char *const argv[], char *const envp[],
                     const char *cwd, unsigned short rows, unsigned short cols,
                     int *master_fd);

/* Opens a PTY pair sized rows x cols. The master is nonblocking; both are
 * CLOEXEC and above stdio. Returns 0, or -1 with errno and both outputs -1.
 * Used when a run host, not Loom, becomes the child's parent. */
int loom_open_pty(unsigned short rows, unsigned short cols, int *master_fd, int *slave_fd);

/* Returns 0 with an allocated snapshot and count (including a valid empty
 * snapshot); -1 with errno on failure. Free snapshots with loom_free_processes.
 * getsid is sampled separately and may report -1 for a disappearing process. */
int loom_processes(loom_process_info **processes, size_t *count);
void loom_free_processes(loom_process_info *processes);

/* One process by pid (same fields as the snapshot). Returns 0, or -1 with errno;
 * ESRCH means no such process. */
int loom_process_for_pid(pid_t pid, loom_process_info *out);

/* Returns 0 with a NUL-terminated executable path, or -1 with errno. A valid
 * output buffer is emptied on failure; insufficient capacity reports ERANGE. */
int loom_process_path(pid_t pid, char *buffer, size_t capacity);

/* Returns 0 with physical footprint in bytes, or -1 with errno. On failure a
 * valid output pointer is set to zero; zero alone must not imply success. */
int loom_physical_footprint(pid_t pid, uint64_t *bytes);

typedef struct {
    uint64_t user_time_ns;
    uint64_t system_time_ns;
    uint64_t package_idle_wakeups;
    uint64_t interrupt_wakeups;
    uint64_t physical_footprint_bytes;
} loom_process_usage;

/* Returns cumulative CPU time, wakeups, and physical footprint for a process.
 * CPU Mach ticks from proc_pid_rusage RUSAGE_INFO_V4 are converted to
 * nanoseconds using mach_timebase_info; all values are suitable for delta
 * measurements. Returns 0 on success or -1 with errno (ERANGE on conversion
 * overflow). A valid output is zeroed on failure; zero does not imply success. */
int loom_process_resource_usage(pid_t pid, loom_process_usage *usage);

/* Query the private XNU resource-coalition ABI. Returns 0 with a nonzero ID,
 * or -1 with errno and a zero output (when non-NULL). ENOTSUP means the reply
 * does not match the known ABI or has no resource coalition. This is only a
 * capability query: the caller must establish exclusivity, user ownership,
 * and process identity separately before using coalition membership. */
int loom_resource_coalition(pid_t pid, uint64_t *coalition_id);

/* Returns 0 with the validated, lowercase kern.bootsessionuuid (36 characters
 * plus NUL), or -1 with errno. A valid output buffer is empty on failure;
 * capacity below 37 reports ERANGE and malformed/zero UUID reports ENOTSUP.
 * Persist alongside coalition IDs and compare before accepting recovered IDs. */
int loom_boot_session_uuid(char *buffer, size_t capacity);

/* Reads only LOOM_RUN_ID from KERN_PROCARGS2. Returns 1 with a NUL-terminated
 * value, 0 if readable but absent, or -1 with errno if inaccessible/malformed or
 * capacity is insufficient (ERANGE). Output is empty unless the result is 1. */
int loom_read_run_id(pid_t pid, char *buffer, size_t capacity);

/* Reads only LOOM_MANAGED_RUN_ID from KERN_PROCARGS2, with the same return
 * contract as loom_read_run_id. This marker distinguishes concurrently or
 * successively managed terminal runs inside one Loom ownership run. */
int loom_read_managed_run_id(pid_t pid, char *buffer, size_t capacity);

/* Re-read PID start time immediately before kill. Returns 0 on success or -1
 * with errno (ESRCH for identity mismatch, EPERM if the target's effective UID
 * differs from the caller's real UID). This narrows but cannot eliminate
 * the kernel API's unavoidable identity-check-to-kill race. pid must be > 1. */
int loom_signal_if_matches(pid_t pid, int64_t start_sec, int64_t start_usec,
                           int signal_number);

/* Run-scope lineage (private XNU proc_pidinfo flavors PROC_PIDUNIQIDENTIFIERINFO
 * and PROC_PIDCOALITIONINFO; both readable for any process without same-user
 * checks). id_version is the kernel's per-process pid version: it is unique for
 * the boot and never reused, so (pid, id_version) identifies one process.
 * launchd_spawned is 1 when the process's original parent at fork time was
 * launchd. The kernel records that original parent at fork and keeps it across
 * exec and reparenting, so a detached descendant never looks launchd-spawned. */
typedef struct {
    pid_t pid;
    uid_t uid;
    int zombie;
    int launchd_spawned;
    int32_t id_version;
    int32_t original_parent_version;
    uint64_t coalition_id;
    int64_t start_sec;
    int64_t start_usec;
} loom_scope_member;

/* Returns 0 or -1 with errno (ESRCH when the process is gone or a zombie whose
 * metadata is unavailable, ENOTSUP when the private reply layout is unknown). */
int loom_process_lineage(pid_t pid, loom_scope_member *member);

/* Lists every live process whose resource coalition is coalition_id. Processes
 * that exit during the scan are skipped; any other unreadable process fails the
 * whole scan (-1 with errno), because its membership cannot be ruled out.
 * Free a successful result with loom_free_scope_members. */
int loom_scope_members(uint64_t coalition_id, loom_scope_member **members, size_t *count);
void loom_free_scope_members(loom_scope_member *members);

/* One pass over the process table for several scopes: every live process whose
 * resource coalition is one of coalition_ids (member.coalition_id tells which).
 * Same failure contract and ownership as loom_scope_members. */
int loom_scopes_members(const uint64_t *coalition_ids, size_t id_count,
                        loom_scope_member **members, size_t *count);

/* Signals pid only if it still has id_version, coalition_id and the caller's
 * real UID. Returns 0, or -1 with errno: ESRCH when the identity no longer
 * matches (the process is gone or its PID was reused), EPERM on another UID. */
int loom_signal_scope_member(pid_t pid, int32_t id_version, uint64_t coalition_id,
                             int signal_number);

/* Freezes then kills every non-launchd member of coalition_id except `exclude`
 * until none remains or timeout_seconds passes. Launchd-spawned members are
 * never signaled. Returns the number of forked members still live (0 means the
 * scope holds no forked work), or -1 with errno when membership is unreadable. */
int loom_kill_scope_forked_members(uint64_t coalition_id, pid_t exclude,
                                   double timeout_seconds);

/* Run-host framing over a SOCK_STREAM Unix socket: u32 little-endian payload
 * length, u8 type, payload. loom_send_frame writes the whole frame and attaches
 * fds (at most 3) to its first byte. loom_receive_frame reads exactly one frame;
 * payload capacity is bounded by `capacity` (EMSGSIZE when exceeded). Received
 * descriptors are returned CLOEXEC in fds/fd_count (at most 3); a frame that
 * carries more is rejected with EPROTO and its descriptors closed. Returns 0, or
 * -1 with errno (ECONNRESET on orderly EOF before a complete frame). */
int loom_send_frame(int socket_fd, uint8_t type, const void *payload, uint32_t length,
                    const int *fds, int fd_count);
int loom_receive_frame(int socket_fd, uint8_t *type, void *payload, uint32_t capacity,
                       uint32_t *length, int *fds, int *fd_count);

/* Peer credentials of a connected Unix socket. */
int loom_socket_peer(int socket_fd, pid_t *pid, uid_t *uid);

/* Peer identity from the socket's audit token: PID, its kernel pid version
 * (unique per process for the boot) and effective UID. */
int loom_socket_peer_version(int socket_fd, pid_t *pid, int32_t *pid_version, uid_t *uid);

#ifdef __cplusplus
}
#endif
#endif
