"""Every Flare v0.12.0 internal the Muntin adapter uses, in one place (M3-049).

`muntin_flare` imports Flare's non-public modules and `HttpServer`'s private
fields only through this module, so a Flare upgrade has one file to check
against the new release: each name below says what it relies on, and the
adapter's tests (`adapters/flare/test_server.mojo`) exercise every one.
Decided in docs/history/architecture-decisions.md "Multi-worker serving
decision (M3-049)" (revisit: the Flare pin moves).
"""

from std.ffi import c_int

from flare.http import Handler, HttpServer, ServerConfig
from flare.http._unified_reactor_impl import run_unified_reactor_loop_shared
from flare.net._libc_event import _pipe
from flare.net.socket import AF_INET, INVALID_FD, SOCK_STREAM, RawSocket
from flare.runtime._thread import ThreadHandle as _ThreadHandle
from flare.runtime._thread import _OpaquePtr as _FlareOpaquePtr
from flare.runtime.scheduler_stats import store_stop_flag

comptime ThreadHandle = _ThreadHandle
"""Flare's OS thread (`flare.runtime._thread`): `spawn_os[start](arg)` runs a
`def(_OpaquePtr) -> _OpaquePtr` start routine on a new pthread; `join`.
Used by the stop watcher (M3-045) and the workers (M3-049)."""

comptime OpaquePtr = _FlareOpaquePtr
"""The argument and result type of a `ThreadHandle` start routine."""


def run_worker_loop[
    H: Handler
](
    listener_fd: Int,
    config: ServerConfig,
    ref handler: H,
    ref stop: Bool,
    tls_context: Int,
) raises:
    """Runs Flare's per-worker reactor loop (`run_unified_reactor_loop_shared`,
    the loop its `Scheduler` runs on each worker) on `listener_fd`, which the
    caller owns and keeps open, serving with `handler` until `stop` is set.
    Relied on: it registers `listener_fd` (with `EPOLLEXCLUSIVE` on Linux),
    reads `stop` with an acquire load before its first poll and every turn,
    leaves its accept loop on `ENOTSOCK`, returns without raising on a failed
    poll, and closes its connections when it leaves. `tls_context` is
    `tls_context_addr`'s value, or 0 for cleartext: with one, every accepted
    connection starts as a TLS handshake on this reactor, as on Flare's own
    workers, which share the one context the same way."""
    run_unified_reactor_loop_shared(
        listener_fd,
        config,
        config.h2.copy(),
        handler,
        stop,
        tls_ctx_addr=tls_context,
    )


def set_stop(stop_addr: Int):
    """Sets the stop byte at `stop_addr` that `run_worker_loop` reads (Flare's
    release store, `store_stop_flag`)."""
    store_stop_flag(stop_addr, True)


def flare_pipe(fds: Pointer[c_int, _]) -> Int:
    """`pipe(2)` through Flare's declaration (`flare.net._libc_event._pipe`),
    the one a program linking Flare already has: 0, or -1 with `errno`."""
    return Int(_pipe(fds))


def listener_fd(server: HttpServer) -> Int:
    """The bound listener's descriptor (`HttpServer._listener`), which the
    `HttpServer` owns."""
    return Int(server._listener.as_raw_fd())


def close_listener(mut server: HttpServer):
    """Closes the bound listener (`HttpServer._listener.close`), as Flare's own
    `drain` does first; idempotent."""
    server._listener.close()


def tls_context_addr(server: HttpServer) -> Int:
    """The address of the TLS context `bind_tls` set
    (`HttpServer._tls_ctx_addr`, the address of `HttpServer._tls_ctx`'s value),
    or 0 when none is bound. It stays valid while `server` is neither moved
    nor destroyed. Relied on: OpenSSL's `SSL_CTX` is shared read-only by
    every thread that makes a connection from it, as Flare's own
    multi-worker `serve` shares it."""
    return server._tls_ctx_addr()


def set_listener_nonblocking(fd: Int) raises:
    """Sets `fd`, a listener the `HttpServer` owns, non-blocking, through
    Flare's `RawSocket.set_nonblocking` (its C wrapper on macOS, where
    `fcntl`'s variadic call is corrupted). The socket is wrapped with the
    private `_wrap=True`, and its `fd` is cleared on every path so the wrapper
    never closes the listener."""
    var raw = RawSocket(c_int(fd), AF_INET, SOCK_STREAM, _wrap=True)
    try:
        raw.set_nonblocking(True)
    except e:
        raw.fd = INVALID_FD
        raise e^
    raw.fd = INVALID_FD
