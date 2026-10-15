/* Fault injection for M3-068 (review of #120), built by run_spread.sh:
   LD_PRELOAD shim that makes every EPOLL_CTL_ADD of a listening socket fail
   with ENOMEM once FAIL_LISTENER_ADD_AFTER such ADDs have succeeded. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/epoll.h>
#include <sys/socket.h>

static atomic_int seen;

int epoll_ctl(int epfd, int op, int fd, struct epoll_event *ev) {
    static int (*real)(int, int, int, struct epoll_event *);
    if (!real) real = dlsym(RTLD_NEXT, "epoll_ctl");
    if (op == EPOLL_CTL_ADD) {
        int listening = 0;
        socklen_t len = sizeof listening;
        if (getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &listening, &len) == 0 && listening) {
            const char *after = getenv("FAIL_LISTENER_ADD_AFTER");
            if (after && atomic_fetch_add(&seen, 1) >= atoi(after)) {
                errno = ENOMEM;
                return -1;
            }
        }
    }
    return real(epfd, op, fd, ev);
}
