# Serving (`muntin_flare.Server`)

`Server` is the Flare adapter module's (`muntin_flare`), not Muntin core's: Muntin core has no `app.run()`. It builds only in the `flare` pixi environment with `-I src -I adapters/flare`, on Linux x86-64 and macOS arm64 (the systems whose `struct sigaction` layout it was verified on). It is a runnable server, not a production-ready deployment: read [the limits](#one-request-at-a-time) before relying on it. Flare v0.12.0; why: [M3-032](../history/decisions/m3-032-serving-entrypoint-decision.md). Each example below is its own program with its own `App`; the later ones use the first one's imports and `hello`, and the line after each names the program or test that runs it, or the nearest test, and what that test changes.

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
- Every setting is keyword-only (`Server.bind("127.0.0.1", 8080, 65536)` does not build: `invalid call to 'bind': unexpected argument`) and checked before anything is bound, in this order: port, `max_body_bytes`, `shutdown_grace_ms`, `idle_timeout_ms`, `max_header_fields`, the host, the `tls` files (both are read, the certificate's first, before either's content is checked, so a missing key file is reported before a certificate file with no certificate; [HTTPS](#https) for the check Flare makes after binding). Out of range raises `<name> out of range: <value>`. An address in use or another OS error raises Flare's text, which is not part of the contract.
- `Server.bind` is the one spelling: `Server("127.0.0.1", 0)` does not build (`no matching function in initialization`), and the initializer's `_`-prefixed keywords are not API.
- Flare's `ServerConfig` defaults apply to everything else (header byte limits, keep-alive, the number of connections, other timeouts).

## `serve`

- `server.serve(app) raises` borrows `app`, as `TestClient(app)` does, so a raise leaves it usable (its `_stage` keyword, and `serve[make]`'s, is a test hook, not API), and serves on the calling thread with one reactor; it does not return while serving (when it returns: below). `App.handle` is never called concurrently.
- Each request that reaches Muntin is answered as `App.handle` answers it, except the adapter's own answers: 400 for a method, target or field it cannot represent (one that is not UTF-8, for example; a body is never refused there, whatever its bytes) or a missing `Host` ([headers](headers.md#through-the-flare-adapter)), 431 past `max_header_fields`, 500 for an invalid outgoing field, and the `HEAD` rule ([routing](routing.md#head)). Flare answers some requests first: over HTTP/1.1 a method that is empty, has a lowercase letter or a non-token byte, or a target byte outside `!`..`~` (400), and a body over `max_body_bytes`.
- Protocols: cleartext HTTP/1.1 and HTTP/2 with prior knowledge (h2c) on one listener; with `tls`, both inside TLS instead. No HTTP/3.
- One `serve` runs at a time in a process, because the signal handlers it installs are process-wide: another `serve` while one runs (from another thread, or from inside a handler) raises `Server.serve is already serving in this process` before touching them. A later `serve`, after the first has returned or raised, is allowed (but see [Stopping](#stopping) for a failed restore).
- `FLARE_BUFRING_HANDLER=1` (Flare's opt-in io_uring loop) is refused on every system: `serve` raises `FLARE_BUFRING_HANDLER=1 is unsupported by Muntin with Flare v0.12.0` before serving; any other value, or none, serves as usual. Measured with Flare's own server, that loop closes h2c connections, and does not answer a request longer than 8,192 bytes on the wire, whatever its body and `max_body_bytes`; while one is pending no other connection is answered, until Flare's 60 s request timeout answers it 408.
- When Flare's `serve` returns, `serve` returns: after a stop, or when Flare's reactor stopped on a failed poll; the two are not distinguished. A raise propagates, except during a stop (a stop that closes the listener before Flare's reactor is set up makes Flare's `serve` raise; `serve` then returns as for any stop). Muntin adds no exit or error policy: a `main` that does nothing after `serve` then ends with status 0.

## One request at a time

**With `serve(app)`, while one handler runs, no other request of the process is answered**, on any connection, and no other stream of an h2c connection; new connections wait in the system's queue ([M3-046](../history/decisions/m3-046-head-of-line-blocking-decision.md)). This is Flare v0.12.0's single reactor, and Flare's own server behaves the same. With [workers](#workers) it holds per worker.

**A long handler can lose requests, not only delay them.** On Flare v0.12.0, because of the order in which its loop handles idle timers, open HTTP/1.1 keep-alive and h2c connections that waited while the handler ran can be closed once it returns, with the requests that arrived on them unread and unanswered (reset, when measured on Linux and macOS), and the handler's own keep-alive connection can be closed right after its answer. That happens when a connection's idle time before the handler plus the handler's run time exceeds `idle_timeout_ms` (500 ms unless set). It is reproduced with a 1 s handler and the default; the general rule is read in Flare's code, not tested. Connections opened during the handler are answered afterwards. Keep handlers short, or set `idle_timeout_ms` above the longest handler run plus the idle time clients leave before a request, so that waiting requests are answered after the handler instead of dropped (tested with a 1 s handler and 60,000; they are still not answered while it runs). Several processes behind a load balancer help requests sent to another process, and workers (below) keep new connections moving within one process; neither helps requests on a held connection or another stream of the same h2c connection.

## Workers

`server.serve[make_app](workers=4)` serves with 4 threads, each with its own `App`, built by calling `make_app` on that thread ([M3-049](../history/decisions/m3-049-multi-worker-serving-decision.md)):

```mojo
def make_app() -> App:
    var app = App()
    app.get["/"](hello)
    return app^


def main() raises:
    var server = Server.bind("127.0.0.1", 8080)
    server.serve[make_app](workers=4)
```

Run by `adapters/flare/test_server.mojo` (`test_docs_workers_example`), with `make_app` as written but that module's `hello`, which answers `"hello"`; it binds port 0 with `shutdown_grace_ms=300`, checks one `GET /` and that SIGTERM ends `serve` with status 0.

- `make_app` is a plain `def() raises -> App` (or without `raises`); a closure is refused at compile time (`has 'def() raises thin -> App' type, but value has type 'def() raises capturing thin -> App'` for a compile-time closure, `cannot use a dynamic value in a parameter list` for one that captures at run time). It captures nothing and Mojo has no global variables, so **workers share no value**, `State` included ([state](state.md#rules)), unless `make_app` reaches shared memory through an unsafe pointer or a C call, which Muntin cannot check. Everything an `App` holds, the JSON parser's memory bound included, is held once per worker.
- `workers` is 1 to 256, else `serve` raises `workers out of range: <value>` before serving; `FLARE_BUFRING_HANDLER=1` and a second `serve` in the process are refused as for `serve(app)`.
- What improves: while one worker's handler runs, a connection opened meanwhile is accepted and answered by another worker (tested over HTTP/1.1 and h2c with 2 workers and a 1 s handler). While one worker is free, a new connection is usually answered at once, but one accepted by a worker that then starts another connection's handler waits behind it, which can happen when connections arrive together (measured on Linux, not tested). What does not improve: a connection stays on the worker that accepted it, so requests on a held worker's open connections, every other stream of the same h2c connection among them, still wait and can still be dropped. While every worker runs a handler, no new connection is answered until one returns. Workers are the capacity for blocking handlers ([M3-071](../history/decisions/m3-071-handler-execution-model-decision.md)), not a setting that removes the limit: Muntin cannot end a running handler, more workers only raise how many may block at once, and a handler still running past a stop's bound ends the process ([Stopping](#stopping)). So a handler that waits on a service should bound that wait itself, and `workers` should exceed the number of such handlers expected at once.
- Connections are not balanced: whichever worker accepts first takes a connection, so connections opened one after another tend to land on one worker (measured on Linux, not guaranteed). A client that keeps a few connections open (a pool, a load balancer, an h2c client) can have most of them on the worker a slow handler holds ([M3-068](../history/decisions/m3-068-worker-connection-spread-decision.md)).
- **Workers are not isolated from each other's failures**: if `make_app` raises on a worker, or a worker's reactor raises or returns, before a stop signal, every worker stops at once, with no grace window, and `serve` raises (`serve: a worker's make raised: <error>`, `serve: a worker's reactor raised: <error>`, `serve: a worker's reactor returned before a stop signal`). Once a stop signal was delivered, the stop goes on and `serve` returns; a worker's error during it is printed to standard error, not raised. "Before" is when `serve`'s thread sees the worker has ended (it looks every 50 ms), not when it ended: a worker that ended just before a stop signal arrived can be seen after it, and its error is then printed and `serve` returns. A `make_app`, a handler or the destructor of a worker's `App` (a `State` value's included) that does not return cannot be interrupted: if a worker has not stopped (its `App` destroyed) 1 s after that stop began, the error is printed and the process ends with status 1, as a stop signal's bound ends it ([Stopping](#stopping)). So a busy worker (a slow handler, or a thread not scheduled in time on a loaded machine) can turn one worker's failure into the end of the process. Run `serve` under a supervisor that restarts it.
- With `tls`, every worker serves HTTPS with the one certificate and key; a TLS handshake runs on the worker that accepted the connection, so a held handler also holds the handshakes of its worker's connections ([M3-060](../history/decisions/m3-060-tls-with-workers-decision.md)). Every worker uses one OpenSSL context at once, which relies on Flare not modifying it after `bind` (not tested under concurrent handshakes); one worker avoids that.

## Receive body limit

`max_body_bytes` bounds the request body the backend receives, over HTTP/1.1 and h2c ([M3-044](../history/decisions/m3-044-server-receive-body-limit-decision.md)):

```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, max_body_bytes=64 * 1024)
    server.serve(app)
```

Run by `adapters/flare/test_server.mojo` (`test_docs_receive_limit_example`), on port 0 and with the handler named `welcome`; it checks that a 65,536-byte body is received (`App.handle`'s 405: no `POST` route on `/`) and that a head declaring 65,537 is Flare's 413 before any body is sent.

- Default 10,485,760 (10 MiB), Muntin's value, equal to Flare v0.12.0's default, not read from Flare. 0 to 2^59 − 1 (0 accepts only empty bodies), else `max_body_bytes out of range: <value>`; past that Flare's chunk-size parsing is not safe (one chunk-size line can abort the serving process). There is no "unlimited" value.
- A longer body is refused by Flare while it arrives, before the adapter: no middleware, routing, conversion or handler runs, on any route, raw routes and paths no route matches included, so the application cannot see, count or answer the refusal. Over HTTP/1.1 a request declaring more with `Content-Length` is refused as soon as its head arrives, without waiting for the body.
- It is a bound, not a promise: over HTTP/1.1 Flare also counts the head, chunk framing and any bytes pipelined in the same burst against the limit plus 8 KiB, so a body within the limit can still be refused (a chunked client should send few, large chunks). A body within the limit sent with `Content-Length` and a head under 8 KiB is never refused for its size when nothing else is buffered with it on the connection.
- What a client sees is Flare's, by protocol (measured by `adapters/flare/test_localhost_roundtrip.mojo`): HTTP/1.1 with `Content-Length`, `413 Content Too Large` (that text as a `text/plain` body) and a closed connection; HTTP/1.1 chunked, `400 Bad Request` (or 413) and a closed connection; h2c, the stream reset (`ENHANCE_YOUR_CALM`) with no response, and the same connection answers its next stream. Flare closes a refused HTTP/1.1 connection without reading the rest of the request, so a client still sending can see a connection reset after the answer, or, on some systems, instead of it. The `Server` keeps serving after each. A connection upgraded with `Upgrade: h2c` builds its HTTP/2 state from the same configuration (read in Flare's code, not tested).
- Not `FromBytes.max_bytes` or `Json[T]`'s 1 MiB: those are `App.handle`'s 413 on a body already received, through middleware, which sees and can change that answer. Over HTTP/1.1 the status alone does not tell which refused.
- It bounds one request body's buffer, not the server's memory (connections, streams, headers and slow clients are Flare's defaults). It is not denial-of-service protection in general and not authentication: any client can send up to the limit, received in full before middleware runs. With a small limit it also bounds how much a client may pipeline in one HTTP/1.1 burst, since Flare counts every buffered byte (above). It is per `Server`, not per route.

## Idle timeout

`idle_timeout_ms` is how long Flare keeps a connection open while nothing arrives on it ([M3-047](../history/decisions/m3-047-server-idle-timeout-decision.md)): before the first byte, between keep-alive requests, between h2c frames (a stalled h2c body included), and while an HTTP/1.1 request head is incomplete. Past it Flare closes the connection with no answer.

```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, idle_timeout_ms=30_000)
    server.serve(app)
```

Not run by a test. The nearest are `adapters/flare/test_server.mojo` (`test_server_config_sets_the_idle_timeout`), which binds port 0 with `idle_timeout_ms=4321` and checks that Flare's configuration holds it, and (`test_idle_timeout_closes_silent_partial_and_h2c_connections`), which serves with 1,000 and checks each close listed above but the keep-alive one.

- Default 500, Muntin's value, equal to Flare v0.12.0's default, not read from Flare. 1 to 86,400,000 (one day), else `idle_timeout_ms out of range: <value>`; the range catches a unit mistake and is not a resource bound (Cost, below). 0 is refused, since Flare would read it as no timer and hold a connection that sends nothing until its client closes it. A value shorter than a client's pause between connecting and sending, or between requests, closes that client's connection.
- It does not bound (read in Flare's code; the HTTP/1.1 body case is tested) an HTTP/1.1 body that is arriving (Flare's 30 s body timer), a response being written (5 s), or a handler. It does not let another request run while a handler runs; it decides whether waiting requests are answered afterwards or dropped.
- **Cost: every idle connection holds a file descriptor and a little memory (about 1.5 to 3 KB measured on Linux) for up to this long, and neither Muntin nor Flare's default caps how many.** Choose the shortest value that covers your slowest handler plus your clients' idle time.
- During a [stop](#stopping) Flare's idle timer keeps running, so a connection idle for `idle_timeout_ms` can be closed inside the window (observed with the default) and every other one is closed at its end; the stop's bound does not change (tested with 60,000 and a 1,500 ms window).
- It is per `Server`: two `Server`s keep their own values (tested).

## Request header field limit

`max_header_fields` is the most header fields a request may carry ([M3-066](../history/decisions/m3-066-request-header-conversion-decision.md)). A request with more is answered `431 Request Header Fields Too Large` (that text as the body) by the adapter, before its fields are converted and before `App.handle`: no middleware, routing or handler runs, on any path, so the application cannot see, count or answer it; for `HEAD` the status and `Content-Length` go out without the body. Of the adapter's own answers, only the 400 for a request without `Host` comes first; Flare's own refusals (its 400s, a body over `max_body_bytes`) come before the adapter's.

```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, max_header_fields=50)
    server.serve(app)
```

Not run by a test. The nearest is `adapters/flare/test_server.mojo` (`test_serve_keeps_the_servers_field_limit`), which binds port 0 with `max_header_fields=3` and checks that a request with 3 fields is answered by `App.handle` and one with 4 is 431.

- Default 100; 1 to 65,535, else `max_header_fields out of range: <value>`.
- It counts the fields as Flare hands them over, `Host` included: over HTTP/1.1 every field line received (`Connection` too), and repeats of a name are separate fields; over h2c `:authority` counts as one `Host` field and every `cookie` field together as one. Every worker and a TLS `Server` apply it.
- Cost of raising it: the adapter's conversion grows with the square of the field count, and every `Headers.get` scans every field. Raise it only for a client that needs more. It bounds the fields Muntin converts, not the bytes Flare parses first. It is per `Server`, not per route.

## HTTPS

With `tls=Tls(cert_file=..., key_file=...)` the `Server` serves the same `App` over TLS instead of cleartext, every route, middleware, setting, worker and the stop unchanged ([M3-051](../history/decisions/m3-051-server-tls-decision.md)):

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

- `Tls(*, cert_file: String, key_file: String)`: the certificate in PEM followed by any intermediates (the chain a client needs), and an unencrypted private key in PEM (PKCS#8 or the older RSA or EC form). Each file is at most 1 MiB (a symbolic link is followed). Muntin opens each path once with `O_NONBLOCK` and stops reading one byte past 1 MiB, so a FIFO with no writer reads as empty, `/dev/zero` as too large and a directory as unreadable, instead of stopping `bind` or filling memory (tested); `O_NONBLOCK` does not make every read immediate, so a slow disk or network file system can still delay `bind`.
- Start-up errors, raised by `bind` naming the file, before anything is bound: `TLS certificate file cannot be read: <path> (<reason>)`, `TLS key file cannot be read: ...`, `TLS certificate file is empty: <path>`, `TLS certificate file is larger than 1048576 bytes: <path>` (and the key file's), `TLS certificate file has no PEM certificate (-----BEGIN CERTIFICATE-----): <path>` (a key or a DER file given as the certificate), `TLS key file has no PEM private key: <path>`, `TLS key file holds an encrypted private key, which is not supported: <path>` (OpenSSL would otherwise stop and ask for its passphrase on the terminal). These are a best-effort diagnosis, not a guarantee: they look only at the lines that begin PEM blocks (text outside them is ignored, and the key judged is the file's first private key block), and whether the files load is OpenSSL's decision alone. When Flare cannot load the pair afterwards (a damaged block, a key that does not match), `bind` raises `TLS certificate or private key could not be loaded: <cert_file>, <key_file>`, naming no cause; that load runs after Flare has bound the port, so on a port in use the address error comes first; the port is free again once `bind` has raised.
- OpenSSL reads the files again from their paths after Muntin's check (Flare v0.12.0 takes paths, not contents): a file replaced between the two is loaded without Muntin's check, and an encrypted key that arrives that way makes OpenSSL ask for its passphrase on the terminal. Replace them before `bind`, not during it. Replacing them after `bind` changes nothing until the process binds again.
- Protocols: ALPN offers `h2` then `http/1.1`. A client that offers no ALPN is served HTTP/1.1. A client whose ALPN list holds neither protocol is served HTTP/1.1 too, with no protocol selected: RFC 7301 section 3.2 says the server SHALL refuse that handshake (`no_application_protocol`), so this is a deviation, Flare v0.12.0's ALPN selection, which Muntin cannot change (tested, so that a Flare change is noticed). TLS 1.2 or later with Flare's forward-secret ciphers. The port serves TLS only: a cleartext request to it gets no answer, and cleartext and HTTPS together take two processes, each with its own `Server` (one `serve` runs at a time per process).
- `idle_timeout_ms` also bounds each pause in a handshake, measured between handshake messages, not the whole handshake (raise it for clients on slow links). There is no handshake deadline and the number of connections is Flare's default, so a client that keeps sending a little within each `idle_timeout_ms` keeps its connection, handshake or not (not measured). `max_body_bytes` refuses a longer body as in cleartext (HTTP/2 inside TLS: the reset stream).
- Flare ignores SIGPIPE in the whole process once `bind` is given `tls`, if its disposition is still the default (OpenSSL writes to sockets without suppressing it); a handler the application installed is left alone (read in Flare v0.12.0's code and documentation, not tested).
- Not provided: automatic certificates or renewal, reload while serving, client certificates (mTLS), choosing versions, ciphers or ALPN, HTTP/3.

## Stopping

While `serve` (or `serve[make]`) runs, SIGTERM and SIGINT ask it to stop ([M3-045](../history/decisions/m3-045-graceful-shutdown-decision.md)). **Graceful means a bounded wait, not a cancellation**: Muntin cannot notify or cancel a running handler.

1. New connections are refused at once (when measured, the listener closed within about 50 ms on Linux and 200 ms on the macOS CI runner; the tests allow one second). A connection the system had already queued but Flare had not yet accepted is closed without an answer.
2. The open connections are served for `shutdown_grace_ms` (default 5,000; 0 to 86,400,000, else `shutdown_grace_ms out of range: <value>`; 0 stops at the next turn of the reactor). The whole window is always waited, even with nothing in flight: Flare v0.12.0's reactor reports no live connections.
3. Flare closes every connection still open and `serve` returns; a `main` that does nothing after it exits with status 0.
4. **If the server has not stopped one second after the window** (a handler still running), **the process ends** with POSIX `_exit` and status 128 + the signal (143 for SIGTERM, 130 for SIGINT). That second is for the server to stop, not more time to serve: a handler that returns within it lets `serve` return, but its request is not promised an answer, and requests still running when the process ends get none. A running handler cannot be interrupted, so ending the process is how Muntin stops it; with workers, one held handler ends every worker's in-flight requests. `_exit` skips destructors that have not run (a held handler's own values, the `App` and `State` values of a worker that has not ended), `atexit` handlers and output still in standard I/O buffers; what was already written to a descriptor is the system's to deliver.

- What must finish within that second: with `serve(app)`, Flare's reactor leaves its loop and the serving thread records that `serve` is done (a serving thread the system does not run in time ends the process too); with `serve[make]`, every worker has ended, its reactor out of its loop and its `App`, `State` values included, destroyed (a slow destructor or a `make_app` still running holds it), and the serving thread has joined it. The second starts once the window has ended and the reactors have been told to stop. The bound after a worker's failure ([Workers](#workers)) ends the process the same way, with status 1 when no stop signal was acted on. Tested: after SIGTERM, a handler that does not return (status 143, no answer); on the worker-failure bound, a worker held in `make_app`, in a handler or in a `State` destructor (status 1). Read in Muntin's and Flare's code, not tested: a destructor or a `make_app` holding a signal's stop, a handler that returns within the second, and what `_exit` skips.
- Promised (tested over HTTP/1.1 and h2c on Linux and macOS): a request whose handler is running when the signal arrives is answered if it returns and its response is written within the window. The process ends within the time to see the signal, the window and one second, whatever clients do (a client that sent half a request and stalls does not delay it). Seeing the signal is not bounded: Muntin's watcher looks for it every 50 ms, and later when the system runs it late (about 200 ms observed on the macOS CI runner). So this is Muntin's bound under the scheduling the tests see, not a real-time one; a supervisor that needs a hard deadline still kills.
- Not promised: a request still being received or a response still being written when the window ends is cut. A request sent on an open keep-alive connection, or a new stream on an open h2c connection, during the window is answered (observed), but the response says `Connection: keep-alive`, h2c sends no `GOAWAY`, and the connection is closed by the window's end at the latest ([idle timeout](#idle-timeout) can close it sooner); clients must retry idempotent requests on a closed connection.
- **What this asks of an application**, two properties Muntin does not provide. No half-done state: a handler can be stopped between any two steps, so make each change that must not be left partial atomic (a transaction, a file written under a temporary name and then renamed). Safe retries: a handler can also finish its work, its commit included, and be stopped before its answer is written, and a client that got no answer may send the request again; atomicity does not prevent that duplicate. An idempotency key the client sends, stored under a unique constraint in the same transaction as the change, keeps a retry from repeating a database change. An effect outside that database (a payment, an email, a message to another service) cannot join its transaction: recorded first and performed after, it can be lost; performed first and recorded after, it can be repeated. It needs more coordination, such as an outbox or the other service's own idempotency support, and whether it happens exactly once then depends on that service. A `shutdown_grace_ms` above your slowest handler lets a handler already running at the signal finish; it does not protect a request started later in the window, which can still be cut.
- A second SIGTERM or SIGINT once the stop has begun (once new connections are refused) ends the process at once by the signal's default action, nothing drained (Ctrl-C twice). As process 1 of a container without an init (`docker run` without `--init`) the kernel ignores it and the stop runs its course; run the program under an init (`--init`, tini) if a second signal must end it.
- A stop signal that arrives as `serve` is ending for another reason is either acted on as a stop, or sent again once the previous handlers are back and before another `serve` in the process can start, so it ends the process as it would outside `serve` (tested by placing the signal at those moments).
- There is no stop call: a program stops its own server by sending itself a signal (`kill(getpid(), SIGTERM)`).
- Outside `serve` (before it starts, after it returns) the signals end the process as usual (the Mojo 1.1.0 runtime's handler). During `serve` they are stop requests whatever the process inherited, an ignored SIGINT of a background job included: the runtime replaces an inherited ignore with its own handler before `main` runs, so `serve` cannot see it.
- `serve` replaces both handlers while it runs and puts back the previous ones when it returns or raises. An application handler installed for them while it serves disables the graceful stop, and code that sets either back to the default while it serves starts a stop. On macOS a handler set with `SA_RESETHAND` comes back without that flag: macOS does not report it when `serve` reads the handler it replaces.
- The thread that calls `serve` must not block SIGTERM or SIGINT in its signal mask (`pthread_sigmask`), before `serve` or while it serves: a stop signal `serve` sends again as it ends (above) goes to that thread, and if that thread blocks it, it stays pending after `serve` has given up the signals and, once unblocked, can stop a later `serve` instead. Muntin blocks neither.
- Failures: if installing the handlers fails, `serve` raises before serving, with the previous ones put back. If putting them back fails, `serve` raises and a signal may keep `serve`'s handler, so no later `serve` in that process is allowed (it raises as already serving). If, once a stop signal is seen, setting both signals back to their default action fails (it cannot on Linux x86-64 or macOS arm64), the stop is not graceful: the process ends at once with status 128 + the signal, nothing drained, rather than risk absorbing a second signal. If Flare's `drain` fails (it cannot on Flare v0.12.0), the stop falls back to Flare's hard stop, which closes the open connections at once, and `serve` raises with `drain`'s error instead of returning.
- Deploying: take the process out of the load balancer before sending SIGTERM (new connections are refused at once), and let the supervisor wait longer than `shutdown_grace_ms` plus one second before it kills (Docker's 10 s and Kubernetes' 30 s defaults exceed the default 6 s).
