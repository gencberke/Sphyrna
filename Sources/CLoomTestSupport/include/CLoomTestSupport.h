#ifndef CLOOM_TEST_SUPPORT_H
#define CLOOM_TEST_SUPPORT_H

#include <sys/types.h>

// Returns zero on success or an errno value. All post-fork work stays in C.
int loom_fixture_spawn(const char *path, const char *const argv[],
                       int escape_session, pid_t *descendant_pid);
void loom_fixture_ignore_termination(void);
void loom_fixture_wait(int stubborn);

#endif
