#ifndef CLOOM_TEST_SUPPORT_H
#define CLOOM_TEST_SUPPORT_H

#include <sys/types.h>

// Returns zero on success or an errno value. All post-fork work stays in C.
int loom_fixture_spawn(const char *path, const char *const argv[],
                       int escape_session, pid_t *descendant_pid);
void loom_fixture_ignore_termination(void);
void loom_fixture_wait(int stubborn);
// Starts a detached, termination-ignoring process family that keeps escaping
// with setsid + double fork and leaves /bin/sleep children, for
// lifetime_seconds. Returns the first churner's pid, or -1 with errno.
pid_t loom_fixture_start_churn(int lifetime_seconds);
// Attaches to (attach != 0) or detaches from pid as a tracer, like a debugger.
// Returns 0 or an errno value.
int loom_fixture_trace(pid_t pid, int attach);

#endif
