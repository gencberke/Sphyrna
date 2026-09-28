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

/* Returns 0 with an allocated snapshot and count (including a valid empty
 * snapshot); -1 with errno on failure. Free snapshots with loom_free_processes.
 * getsid is sampled separately and may report -1 for a disappearing process. */
int loom_processes(loom_process_info **processes, size_t *count);
void loom_free_processes(loom_process_info *processes);

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
 * Values come from proc_pid_rusage RUSAGE_INFO_V4 and are suitable for delta
 * measurements. Returns 0 on success or -1 with errno. */
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

#ifdef __cplusplus
}
#endif
#endif
