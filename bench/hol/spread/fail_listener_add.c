/* Fault injection for M3-068 (review of #120) and M3-069, built by
   run_spread.sh: LD_PRELOAD shim that makes an EPOLL_CTL_ADD of a listening
   socket fail with ENOMEM once FAIL_LISTENER_ADD_AFTER such ADDs have
   succeeded (an ADD the kernel refuses, such as Flare v0.12.0's
   EPOLLEXCLUSIVE with EPOLLRDHUP, is not counted). From then on every one
   fails, or, with FAIL_LISTENER_ADD_COUNT=n, only the next n attempts, or,
   with FAIL_LISTENER_ADD_EVERY=n, the first of every n attempts.
   FAIL_LISTENER_ADD_ERRNO=n fails with errno n instead of ENOMEM.
   FAIL_LISTENER_ADD_EXCLUSIVE=1 instead fails every listener ADD that asks
   for EPOLLEXCLUSIVE, from the first, as a kernel before 4.5 does (with
   EINVAL when FAIL_LISTENER_ADD_ERRNO=22). FAIL_LISTENER_ADD_DELAY_MS=n
   makes the first failure return only after n ms, as if the worker had
   spent them since it last read the clock (a slow handler earlier in the
   same batch of events). Each failure it makes writes a line to standard
   error. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static atomic_int succeeded, attempted;

static int env(const char *name) {
    const char *value = getenv(name);
    return value ? atoi(value) : 0;
}

int epoll_ctl(int epfd, int op, int fd, struct epoll_event *ev) {
    static int (*real)(int, int, int, struct epoll_event *);
    if (!real) real = dlsym(RTLD_NEXT, "epoll_ctl");
    int listening = 0;
    socklen_t len = sizeof listening;
    int exclusive = env("FAIL_LISTENER_ADD_EXCLUSIVE");
    if (op != EPOLL_CTL_ADD || (!exclusive && !getenv("FAIL_LISTENER_ADD_AFTER")) ||
        getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &len) != 0 || !listening)
        return real(epfd, op, fd, ev);
    int fail = 0;
    if (exclusive) {
        fail = ev && (ev->events & EPOLLEXCLUSIVE);
    } else if (atomic_load(&succeeded) >= env("FAIL_LISTENER_ADD_AFTER")) {
        int n = atomic_fetch_add(&attempted, 1);
        int count = env("FAIL_LISTENER_ADD_COUNT"), every = env("FAIL_LISTENER_ADD_EVERY");
        fail = count > 0 ? n < count : every > 0 ? n % every == 0 : 1;
    }
    if (fail) {
        static const char line[] = "fail_listener_add: injected\n";
        static atomic_int delayed;
        int delay = env("FAIL_LISTENER_ADD_DELAY_MS");
        if (delay > 0 && atomic_exchange(&delayed, 1) == 0) {
            struct timespec ts = {delay / 1000, (delay % 1000) * 1000000L};
            nanosleep(&ts, NULL);
        }
        (void)!write(2, line, sizeof line - 1);
        errno = getenv("FAIL_LISTENER_ADD_ERRNO") ? env("FAIL_LISTENER_ADD_ERRNO") : ENOMEM;
        return -1;
    }
    int rc = real(epfd, op, fd, ev);
    if (rc == 0) atomic_fetch_add(&succeeded, 1);
    return rc;
}
