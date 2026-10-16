/* Fault injection for M3-068 (review of #120) and M3-069, built by
   run_spread.sh: LD_PRELOAD shim that makes an EPOLL_CTL_ADD of a listening
   socket fail with ENOMEM once FAIL_LISTENER_ADD_AFTER such ADDs have
   succeeded (an ADD the kernel refuses, such as Flare v0.12.0's
   EPOLLEXCLUSIVE with EPOLLRDHUP, is not counted). From then on every one
   fails, or, with FAIL_LISTENER_ADD_COUNT=n, only the next n attempts, or,
   with FAIL_LISTENER_ADD_EVERY=n, the first of every n attempts. Each
   failure it makes writes a line to standard error. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/socket.h>
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
    if (op != EPOLL_CTL_ADD || !getenv("FAIL_LISTENER_ADD_AFTER") ||
        getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &len) != 0 || !listening)
        return real(epfd, op, fd, ev);
    if (atomic_load(&succeeded) >= env("FAIL_LISTENER_ADD_AFTER")) {
        int n = atomic_fetch_add(&attempted, 1);
        int count = env("FAIL_LISTENER_ADD_COUNT"), every = env("FAIL_LISTENER_ADD_EVERY");
        if (count > 0 ? n < count : every > 0 ? n % every == 0 : 1) {
            static const char line[] = "fail_listener_add: ENOMEM\n";
            (void)!write(2, line, sizeof line - 1);
            errno = ENOMEM;
            return -1;
        }
    }
    int rc = real(epfd, op, fd, ev);
    if (rc == 0) atomic_fetch_add(&succeeded, 1);
    return rc;
}
