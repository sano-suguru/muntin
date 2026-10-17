# Serving (`muntin_flare.Server`)

`Server` is the Flare adapter module's (`muntin_flare`), not Muntin core's: Muntin core has no `app.run()`. It builds only in the `flare` pixi environment with `-I src -I adapters/flare`, on Linux x86-64 and macOS arm64 (the systems whose `struct sigaction` layout it was verified on). It is a runnable server, not a production-ready deployment: read [the limits](#one-request-at-a-time) before relying on it. Flare v0.12.0; why: [M3-032](../history/architecture-decisions.md#serving-entrypoint-decision-m3-032). Each example below is its own program with its own `App`; the later ones use the first one's imports and `hello`, and the line after each names the program or test that runs it, or the nearest test, and what that test changes.

<!-- example: examples/hello_server.mojo -->
```mojo
from muntin import App
from muntin_flare import Server


def hello() -> String:
    return "Hello, Mojo!"


def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080)
    print("listening on http://127.0.0.1:" + String(server.port()))
    server.serve(app)
```

This is `examples/hello_server.mojo`, as written. `scripts/check_flare.sh` builds it and does not run it (it binds port 8080); from a clone it runs as `pixi run -e flare mojo run -I src -I adapters/flare examples/hello_server.mojo`. `adapters/flare/test_server.mojo` serves through `Server` on port 0.

## `Server.bind`

`Server.bind(host: String, port: Int, *, max_body_bytes: Int = 10485760, shutdown_grace_ms: Int = 5000, idle_timeout_ms: Int = 500, max_header_fields: Int = 100, tls: Optional[Tls] = None) raises -> Server`

- It binds and listens before it returns, so a client may connect as soon as it returns. Dropping the `Server` closes its listener, so the port can be bound again.
- `host` is an IPv4 or IPv6 literal (`"127.0.0.1"`, `"0.0.0.0"`, `"::1"`), never a name: `"localhost"` raises.
- `port` is 0 to 65535 (0 lets the system choose; `server.port()` returns the bound port), else `port out of range: <port>`.
- Every setting is keyword-only and checked before anything is bound, in this order: port, `max_body_bytes`, `shutdown_grace_ms`, `idle_timeout_ms`, `max_header_fields`, the host, the `tls` files ([HTTPS](#https) for the check Flare makes after binding). Out of range raises `<name> out of range: <value>`. An address in use or another OS error raises Flare's text, which is not part of the contract.
- `Server.bind` is the one spelling; the initializer's `_`-prefixed keywords are not API.
- Flare's `ServerConfig` defaults apply to everything else (header byte limits, keep-alive, the number of connections, other timeouts).

## `serve`

- `server.serve(app) raises` borrows `app`, so a raise leaves it usable, and serves on the calling thread with one reactor; it does not return while serving (when it returns: below). `App.handle` is never called concurrently.
- Each request that reaches Muntin is answered as `App.handle` answers it, except the adapter's own answers: 400 for a method, target or field it cannot represent or a missing `Host` ([headers](headers.md#through-the-flare-adapter)), 431 past `max_header_fields`, 500 for an invalid outgoing field, and the `HEAD` rule ([routing](routing.md#head)). Flare answers some requests first: over HTTP/1.1 a method that is empty, has a lowercase letter or a non-token byte, or a target byte outside `!`..`~` (400), and a body over `max_body_bytes`.
- Protocols: cleartext HTTP/1.1 and HTTP/2 with prior knowledge (h2c) on one listener; with `tls`, both inside TLS instead. No HTTP/3.
- One `serve` runs at a time in a process, because the signal handlers it installs are process-wide: another `serve` while one runs (from another thread, or from inside a handler) raises `Server.serve is already serving in this process` before touching them. A later `serve`, after the first has returned or raised, is allowed (but see [Stopping](#stopping) for a failed restore).
- `FLARE_BUFRING_HANDLER=1` (Flare's opt-in io_uring loop) is refused on every system: `serve` raises `FLARE_BUFRING_HANDLER=1 is unsupported by Muntin with Flare v0.12.0` before serving; any other value, or none, serves as usual. Measured with Flare's own server, that loop closes h2c connections, and does not answer a request longer than 8,192 bytes on the wire; while one is pending no other connection is answered, until Flare's 60 s request timeout answers it 408.
- When Flare's `serve` returns, `serve` returns: after a stop, or when Flare's reactor stopped on a failed poll; the two are not distinguished. A raise propagates, except during a stop.

## One request at a time

**With `serve(app)`, while one handler runs, no other request of the process is answered**, on any connection, and no other stream of an h2c connection; new connections wait in the system's queue ([M3-046](../history/architecture-decisions.md#head-of-line-blocking-decision-m3-046)). This is Flare v0.12.0's single reactor, and Flare's own server behaves the same. With [workers](#workers) it holds per worker.

**A long handler can lose requests, not only delay them.** On Flare v0.12.0, because of the order in which its loop handles idle timers, open HTTP/1.1 keep-alive and h2c connections that waited while the handler ran can be closed once it returns, with the requests that arrived on them unread and unanswered (reset, when measured on Linux and macOS), and the handler's own keep-alive connection can be closed right after its answer. That happens when a connection's idle time before the handler plus the handler's run time exceeds `idle_timeout_ms` (500 ms unless set). It is reproduced with a 1 s handler and the default; the general rule is read in Flare's code, not tested. Connections opened during the handler are answered afterwards. Keep handlers short, or set `idle_timeout_ms` above the longest handler run plus the idle time clients leave before a request, so that waiting requests are answered after the handler instead of dropped (tested with a 1 s handler and 60,000; they are still not answered while it runs). Several processes behind a load balancer help requests sent to another process, and workers (below) keep new connections moving within one process; neither helps requests on a held connection or another stream of the same h2c connection.

## Workers

`server.serve[make_app](workers=4)` serves with 4 threads, each with its own `App`, built by calling `make_app` on that thread ([M3-049](../history/architecture-decisions.md#multi-worker-serving-decision-m3-049)):

<!-- example: adapters/flare/test_server.mojo#serving-workers workers_main=main -->
```mojo
def make_app() -> App:
    var app = App()
    app.get["/"](hello)
    return app^


def main() raises:
    var server = Server.bind("127.0.0.1", 8080)
    server.serve[make_app](workers=4)
```

Built as written, with `main` named `workers_main`, in `adapters/flare/test_server.mojo`, which `scripts/check_flare.sh` builds; never run, since it binds port 8080. That module's `test_docs_workers_example` serves `make_app` as written but with that module's `hello`, which answers `"hello"`; it binds port 0 with `shutdown_grace_ms=300`, checks one `GET /` and that SIGTERM ends `serve` with status 0.

- `make_app` is a plain `def() raises -> App` (or without `raises`); a closure is refused at compile time. **Workers share no value**, `State` included, unless `make_app` reaches shared memory through an unsafe pointer or a C call, which Muntin cannot check. Everything an `App` holds is held once per worker.
- `workers` is 1 to 256, else `serve` raises `workers out of range: <value>` before serving; `FLARE_BUFRING_HANDLER=1` and a second `serve` in the process are refused as for `serve(app)`.
- What improves: while one worker's handler runs, a connection opened meanwhile is accepted and answered by another worker (tested over HTTP/1.1 and h2c with 2 workers and a 1 s handler). While one worker is free, a new connection is usually answered at once, but one accepted by a worker that then starts another connection's handler waits behind it, which can happen when connections arrive together (measured on Linux, not tested). What does not improve: a connection stays on the worker that accepted it, so requests on a held worker's open connections, every other stream of the same h2c connection among them, still wait and can still be dropped. While every worker runs a handler, no new connection is answered until one returns. Workers are the capacity for blocking handlers ([M3-071](../history/architecture-decisions.md#handler-execution-model-decision-m3-071)): Muntin cannot end a running handler, so a handler that waits on a service should bound that wait itself, and `workers` should exceed the number of such handlers expected at once.
- Connections are not balanced: whichever worker accepts first takes a connection, so connections opened one after another tend to land on one worker (measured on Linux, not guaranteed). A client that keeps a few connections open (a pool, a load balancer, an h2c client) can have most of them on the worker a slow handler holds ([M3-068](../history/architecture-decisions.md#worker-connection-spread-decision-m3-068)).
- **Workers are not isolated from each other's failures**: if `make_app` raises on a worker, or a worker's reactor raises or returns, before a stop signal, every worker stops at once, with no grace window, and `serve` raises (`serve: a worker's make raised: <error>`, `serve: a worker's reactor raised: <error>`, `serve: a worker's reactor returned before a stop signal`). Once a stop signal was delivered, the stop goes on and `serve` returns; a worker's error during it is printed to standard error. A worker that has not stopped (its `App` destroyed) 1 s after that stop began (a `make_app`, handler or `App` destructor that does not return) ends the process with status 1. Run `serve` under a supervisor that restarts it.
- With `tls`, every worker serves HTTPS with the one certificate and key; a TLS handshake runs on the worker that accepted the connection, so a held handler also holds the handshakes of its worker's connections ([M3-060](../history/architecture-decisions.md#tls-with-workers-decision-m3-060)). Every worker uses one OpenSSL context at once, which relies on Flare not modifying it after `bind` (not tested under concurrent handshakes); one worker avoids that.

## Receive body limit

`max_body_bytes` bounds the request body the backend receives, over HTTP/1.1 and h2c ([M3-044](../history/architecture-decisions.md#server-receive-body-limit-decision-m3-044)):

<!-- example: adapters/flare/test_server.mojo#serving-receive-limit receive_limit_main=main -->
```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, max_body_bytes=64 * 1024)
    server.serve(app)
```

Built as written, with `main` named `receive_limit_main`, in `adapters/flare/test_server.mojo`, and never run, as the workers example is. That module's `test_docs_receive_limit_example` runs it on port 0 and with the handler named `welcome`; it checks that a 65,536-byte body is received (`App.handle`'s 405: no `POST` route on `/`) and that a head declaring 65,537 is Flare's 413 before any body is sent.

- Default 10,485,760 (10 MiB); 0 to 2^59 − 1 (0 accepts only empty bodies). There is no "unlimited" value.
- A longer body is refused by Flare while it arrives, before the adapter: no middleware, routing or handler runs, on any route, so the application cannot see or answer the refusal. Over HTTP/1.1 a request declaring more with `Content-Length` is refused as soon as its head arrives, without waiting for the body.
- It is a bound, not a promise: over HTTP/1.1 Flare also counts the head, chunk framing and any bytes pipelined in the same burst against the limit plus 8 KiB, so a body within the limit can still be refused (a chunked client should send few, large chunks). A body within the limit sent with `Content-Length` and a head under 8 KiB is never refused for its size when nothing else is buffered with it on the connection.
- What a client sees is Flare's, by protocol (measured by `adapters/flare/test_localhost_roundtrip.mojo`): HTTP/1.1 with `Content-Length`, `413 Content Too Large` and a closed connection; HTTP/1.1 chunked, `400 Bad Request` (or 413) and a closed connection; h2c, the stream reset (`ENHANCE_YOUR_CALM`) with no response, and the same connection answers its next stream. Flare closes a refused HTTP/1.1 connection without reading the rest of the request, so a client still sending can see a connection reset after the answer, or, on some systems, instead of it. The `Server` keeps serving after each. A connection upgraded with `Upgrade: h2c` builds its HTTP/2 state from the same configuration (read in Flare's code, not tested).
- Not `FromBytes.max_bytes` or `Json[T]`'s 1 MiB: those are `App.handle`'s 413 on a body already received, through middleware. Over HTTP/1.1 the status alone does not tell which refused.
- It bounds one request body's buffer, not the server's memory (connections, streams, headers and slow clients are Flare's defaults). It is not denial-of-service protection in general and not authentication: any client can send up to the limit, received in full before middleware runs. It is per `Server`, not per route.

## Idle timeout

`idle_timeout_ms` is how long Flare keeps a connection open while nothing arrives on it ([M3-047](../history/architecture-decisions.md#server-idle-timeout-decision-m3-047)): before the first byte, between keep-alive requests, between h2c frames (a stalled h2c body included), and while an HTTP/1.1 request head is incomplete. Past it Flare closes the connection with no answer.

<!-- example: adapters/flare/test_server.mojo#serving-idle-timeout idle_timeout_main=main -->
```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, idle_timeout_ms=30_000)
    server.serve(app)
```

Built as written, with `main` named `idle_timeout_main`, in `adapters/flare/test_server.mojo`, and never run, as the workers example is. The nearest are that module's `test_server_config_sets_the_idle_timeout`, which binds port 0 with `idle_timeout_ms=4321` and checks that Flare's configuration holds it, and `test_idle_timeout_closes_silent_partial_and_h2c_connections`, which serves with 1,000 and checks each close listed above but the keep-alive one.

- Default 500; 1 to 86,400,000 (one day), else `idle_timeout_ms out of range: <value>`. 0 is refused, since Flare would read it as no timer. A value shorter than a client's pause closes that client's connection.
- It does not bound (read in Flare's code; the HTTP/1.1 body case is tested) an HTTP/1.1 body that is arriving (Flare's 30 s body timer), a response being written (5 s), or a handler. It does not let another request run while a handler runs; it decides whether waiting requests are answered afterwards or dropped.
- **Cost: every idle connection holds a file descriptor and a little memory (about 1.5 to 3 KB measured on Linux) for up to this long, and neither Muntin nor Flare's default caps how many.** Choose the shortest value that covers your slowest handler plus your clients' idle time.

## Request header field limit

`max_header_fields` is the most header fields a request may carry ([M3-066](../history/architecture-decisions.md#request-header-conversion-decision-m3-066)). A request with more is answered `431 Request Header Fields Too Large` by the adapter, before `App.handle` and middleware, on any path; for `HEAD` without the body. Of the adapter's own answers, only the 400 for a request without `Host` comes first; Flare's own refusals (its 400s, a body over `max_body_bytes`) come before the adapter's.

<!-- example: adapters/flare/test_server.mojo#serving-field-limit field_limit_main=main -->
```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, max_header_fields=50)
    server.serve(app)
```

Built as written, with `main` named `field_limit_main`, in `adapters/flare/test_server.mojo`, and never run, as the workers example is. The nearest is that module's `test_serve_keeps_the_servers_field_limit`, which binds port 0 with `max_header_fields=3` and checks that a request with 3 fields is answered by `App.handle` and one with 4 is 431.

- Default 100; 1 to 65,535, else `max_header_fields out of range: <value>`.
- It counts the fields as Flare hands them over, `Host` included; over h2c `:authority` counts as one `Host` field and every `cookie` field together as one. Every worker and a TLS `Server` apply it.
- Cost of raising it: the adapter's conversion grows with the square of the field count, and every `Headers.get` scans every field. Raise it only for a client that needs more. It bounds the fields Muntin converts, not the bytes Flare parses first. It is per `Server`, not per route.

## HTTPS

With `tls=Tls(cert_file=..., key_file=...)` the `Server` serves the same `App` over TLS instead of cleartext, every route, middleware, setting, worker and the stop unchanged ([M3-051](../history/architecture-decisions.md#server-tls-decision-m3-051)):

<!-- example: examples/hello_https.mojo -->
```mojo
from muntin import App
from muntin_flare import Server, Tls


def hello() -> String:
    return "Hello, Mojo!"


def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind(
        "127.0.0.1",
        8443,
        tls=Tls(cert_file="cert.pem", key_file="key.pem"),
    )
    print("listening on https://127.0.0.1:" + String(server.port()))
    server.serve(app)
```

This is `examples/hello_https.mojo`, as written. `scripts/check_flare.sh` builds it and does not run it (it binds port 8443 and reads `cert.pem` and `key.pem` from the working directory); bind `"0.0.0.0"` to accept connections from other hosts. `adapters/flare/test_tls.mojo` serves over TLS on port 0 with test certificates.

- `Tls(*, cert_file: String, key_file: String)`: the certificate in PEM followed by any intermediates (the chain a client needs), and an unencrypted private key in PEM (PKCS#8 or the older RSA or EC form). Each file is at most 1 MiB.
- Start-up errors, raised by `bind` naming the file, before anything is bound: `TLS certificate file cannot be read: <path> (<reason>)`, `TLS key file cannot be read: ...`, `TLS certificate file is empty: <path>`, `TLS certificate file is larger than 1048576 bytes: <path>` (and the key file's), `TLS certificate file has no PEM certificate (-----BEGIN CERTIFICATE-----): <path>`, `TLS key file has no PEM private key: <path>`, `TLS key file holds an encrypted private key, which is not supported: <path>`. These are a best-effort diagnosis. When Flare cannot load the pair afterwards (a damaged block, a key that does not match), `bind` raises `TLS certificate or private key could not be loaded: <cert_file>, <key_file>`, naming no cause; that load runs after Flare has bound the port, so on a port in use the address error comes first.
- OpenSSL reads the files again from their paths after Muntin's check: replace them before `bind`, not during it. Replacing them after `bind` changes nothing until the process binds again.
- Protocols: ALPN offers `h2` then `http/1.1`. A client that offers no ALPN is served HTTP/1.1. A client whose ALPN list holds neither protocol is served HTTP/1.1 too, with no protocol selected: RFC 7301 section 3.2 says the server SHALL refuse that handshake (`no_application_protocol`), so this is a deviation, Flare v0.12.0's ALPN selection, which Muntin cannot change (tested, so that a Flare change is noticed). TLS 1.2 or later with Flare's forward-secret ciphers. The port serves TLS only: a cleartext request to it gets no answer, and cleartext and HTTPS together take two processes, each with its own `Server` (one `serve` runs at a time per process).
- `idle_timeout_ms` also bounds each pause in a handshake, measured between handshake messages, not the whole handshake; there is no handshake deadline.
- Flare ignores SIGPIPE in the whole process once `bind` is given `tls`, if its disposition is still the default; a handler the application installed is left alone (read in Flare v0.12.0's code and documentation, not tested).
- Not provided: automatic certificates or renewal, reload while serving, client certificates (mTLS), choosing versions, ciphers or ALPN, HTTP/3.

## Stopping

While `serve` (or `serve[make]`) runs, SIGTERM and SIGINT ask it to stop ([M3-045](../history/architecture-decisions.md#graceful-shutdown-decision-m3-045)). **Graceful means a bounded wait, not a cancellation**: Muntin cannot notify or cancel a running handler.

1. New connections are refused at once (when measured, the listener closed within about 50 ms on Linux and 200 ms on the macOS CI runner; the tests allow one second). A connection the system had already queued but Flare had not yet accepted is closed without an answer.
2. The open connections are served for `shutdown_grace_ms` (default 5,000; 0 to 86,400,000). The whole window is always waited, even with nothing in flight.
3. Flare closes every connection still open and `serve` returns; a `main` that does nothing after it exits with status 0.
4. **If the server has not stopped one second after the window** (a handler still running), **the process ends** with POSIX `_exit` and status 128 + the signal (143 for SIGTERM, 130 for SIGINT), and requests still running get no answer; with workers, one held handler ends every worker's in-flight requests. `_exit` skips destructors that have not run, `atexit` handlers and buffered standard output (read in Muntin's and Flare's code, not tested).

- Promised (tested over HTTP/1.1 and h2c on Linux and macOS): a request whose handler is running when the signal arrives is answered if it returns and its response is written within the window. The process ends within the time to see the signal, the window and one second, whatever clients do (under the scheduling the tests see; a supervisor that needs a hard deadline still kills).
- Not promised: a request still being received or a response still being written when the window ends is cut. A request sent on an open keep-alive connection, or a new stream on an open h2c connection, during the window is answered (observed), but the response says `Connection: keep-alive`, h2c sends no `GOAWAY`, and the connection is closed by the window's end at the latest; clients must retry idempotent requests on a closed connection.
- **What this asks of an application**: a handler can be stopped between any two steps, so make each change that must not be left partial atomic (a transaction, a write then rename). A handler can also finish its work and be stopped before its answer is written, and the client may retry: an idempotency key stored under a unique constraint in the same transaction keeps a retry from repeating a database change; an effect outside that database (a payment, an email) needs more coordination, such as an outbox.
- A second SIGTERM or SIGINT once the stop has begun ends the process at once (Ctrl-C twice), except as process 1 of a container without an init (`docker run` without `--init`), where it is ignored.
- There is no stop call: a program stops its own server by sending itself a signal (`kill(getpid(), SIGTERM)`).
- During `serve` the signals are stop requests whatever the process inherited, an ignored SIGINT included; `serve` puts back the previous handlers when it returns or raises. An application handler installed for them while serving disables the graceful stop. The thread that calls `serve` must not block SIGTERM or SIGINT. If installing or restoring the handlers fails, `serve` raises; when putting them back fails, no later `serve` in that process is allowed (it raises as already serving).
- Deploying: take the process out of the load balancer before sending SIGTERM, and let the supervisor wait longer than `shutdown_grace_ms` plus one second before it kills (Docker's 10 s and Kubernetes' 30 s defaults exceed the default 6 s).
