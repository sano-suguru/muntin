# Serving (`muntin_flare.Server`)

`Server` is the Flare adapter module's (`muntin_flare`), not Muntin core's: Muntin core has no `app.run()`. It builds only in the `flare` pixi environment with `-I src -I adapters/flare`, on Linux x86-64 and macOS arm64. It is a runnable server, not a production-ready deployment: read [the limits](#one-request-at-a-time) before relying on it. Flare v0.12.0; why: [M3-032](../history/architecture-decisions.md#serving-entrypoint-decision-m3-032).

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

(`examples/hello_server.mojo`; from a clone: `pixi run -e flare mojo run -I src -I adapters/flare examples/hello_server.mojo`.)

## `Server.bind`

`Server.bind(host: String, port: Int, *, max_body_bytes: Int = 10485760, shutdown_grace_ms: Int = 5000, idle_timeout_ms: Int = 500, max_header_fields: Int = 100, tls: Optional[Tls] = None) raises -> Server`

- It binds and listens before it returns, so a client may connect as soon as it returns. Dropping the `Server` closes its listener.
- `host` is an IPv4 or IPv6 literal (`"127.0.0.1"`, `"0.0.0.0"`, `"::1"`), never a name: `"localhost"` raises.
- `port` is 0 to 65535 (0 lets the system choose; `server.port()` returns the bound port), else `port out of range: <port>`.
- Every setting is keyword-only and checked before anything is bound, in this order: port, `max_body_bytes`, `shutdown_grace_ms`, `idle_timeout_ms`, `max_header_fields`, the host, the `tls` files. Out of range raises `<name> out of range: <value>`. An address in use or another OS error raises Flare's text, which is not part of the contract.
- `Server.bind` is the one spelling; the initializer's `_`-prefixed keywords are not API.
- Flare's `ServerConfig` defaults apply to everything else (header byte limits, keep-alive, the number of connections, other timeouts).

## `serve`

- `server.serve(app) raises` borrows `app` and serves on the calling thread with one reactor until it is stopped (below). `App.handle` is never called concurrently.
- Each request that reaches Muntin is answered as `App.handle` answers it, except the adapter's own answers: 400 for a method, target or field it cannot represent or a missing `Host` ([headers](headers.md#through-the-flare-adapter)), 431 past `max_header_fields`, 500 for an invalid outgoing field, and the `HEAD` rule ([routing](routing.md#head)). Flare answers some requests first: over HTTP/1.1 a method that is empty, has a lowercase letter or a non-token byte, or a target byte outside `!`..`~` (400), and a body over `max_body_bytes`.
- Protocols: cleartext HTTP/1.1 and HTTP/2 with prior knowledge (h2c) on one listener; with `tls`, both inside TLS instead. No HTTP/3.
- Only one `serve` runs in a process: another raises `Server.serve is already serving in this process`.
- `FLARE_BUFRING_HANDLER=1` (Flare's opt-in io_uring loop) is refused: `serve` raises `FLARE_BUFRING_HANDLER=1 is unsupported by Muntin with Flare v0.12.0` before serving. That loop closes h2c connections and stalls the server on a request over 8,192 bytes.
- When Flare's `serve` returns, `serve` returns: after a stop, or when Flare's reactor stopped on a failed poll; the two are not distinguished. A raise propagates, except during a stop.

## One request at a time

**While one handler runs, no other request of the process is answered**, on any connection, and no other stream of an h2c connection; new connections wait ([M3-046](../history/architecture-decisions.md#head-of-line-blocking-decision-m3-046)). This is Flare v0.12.0's single reactor.

**A long handler can lose requests, not only delay them**: connections that waited while it ran can be closed once it returns, with their requests unanswered, when a connection's idle time plus the handler's run time exceeds `idle_timeout_ms` (500 ms unless set). Keep handlers short, or set `idle_timeout_ms` above the longest handler run plus the idle time clients leave before a request. Workers (below) or several processes behind a load balancer keep new connections moving; neither helps requests on a held connection.

## Workers

`server.serve[make_app](workers=4)` serves with 4 threads, each with its own `App`, built by calling `make_app` on that thread ([M3-049](../history/architecture-decisions.md#multi-worker-serving-decision-m3-049)):

```mojo
def make_app() -> App:
    var app = App()
    app.get["/"](hello)
    return app^


def main() raises:
    var server = Server.bind("127.0.0.1", 8080)
    server.serve[make_app](workers=4)
```

- `make_app` is a plain `def() raises -> App` (or without `raises`); a closure is refused at compile time. **Workers share no value**, `State` included, unless `make_app` reaches shared memory through an unsafe pointer or a C call, which Muntin cannot check. Everything an `App` holds is held once per worker.
- `workers` is 1 to 256, else `workers out of range: <value>`.
- What improves: while one worker's handler runs, a new connection is accepted and answered by another worker. What does not: a connection stays on the worker that accepted it, so requests on a held worker's open connections, every stream of the same h2c connection among them, still wait and can still be dropped. While every worker runs a handler, no new connection is answered. Workers are the capacity for blocking handlers ([M3-071](../history/architecture-decisions.md#handler-execution-model-decision-m3-071)): Muntin cannot end a running handler, so a handler that waits on a service should bound that wait itself, and `workers` should exceed the number of such handlers expected at once.
- Connections are not balanced: whichever worker accepts first takes a connection, so connections opened one after another tend to land on one worker (measured on Linux, not guaranteed). A client that keeps a few connections open (a pool, a load balancer, an h2c client) can have most of them on the worker a slow handler holds ([M3-068](../history/architecture-decisions.md#worker-connection-spread-decision-m3-068)).
- **Workers are not isolated from each other's failures**: if `make_app` raises on a worker, or a worker's reactor raises or returns, before a stop signal, every worker stops at once and `serve` raises (`serve: a worker's make raised: <error>`, `serve: a worker's reactor raised: <error>`, `serve: a worker's reactor returned before a stop signal`). A worker that has not stopped 1 s later (a `make_app`, handler or `App` destructor that does not return) ends the process with status 1. Run `serve` under a supervisor that restarts it.
- With `tls`, every worker serves HTTPS with the one certificate and key; a TLS handshake runs on the worker that accepted the connection ([M3-060](../history/architecture-decisions.md#tls-with-workers-decision-m3-060)). Every worker uses one OpenSSL context at once, which relies on Flare not modifying it after `bind` (not tested under concurrent handshakes); one worker avoids that.

## Receive body limit

`max_body_bytes` bounds the request body the backend receives, over HTTP/1.1 and h2c ([M3-044](../history/architecture-decisions.md#server-receive-body-limit-decision-m3-044)):

```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, max_body_bytes=64 * 1024)
    server.serve(app)
```

- Default 10,485,760 (10 MiB); 0 to 2^59 − 1 (0 accepts only empty bodies). There is no "unlimited" value.
- A longer body is refused by Flare while it arrives, before the adapter: no middleware, routing or handler runs, on any route, so the application cannot see or answer the refusal. A request declaring more with `Content-Length` is refused as soon as its head arrives.
- It is a bound, not a promise: over HTTP/1.1 Flare also counts the head, chunk framing and any bytes pipelined in the same burst against the limit plus 8 KiB, so a body within the limit can still be refused (a chunked client should send few, large chunks).
- What a client sees, by protocol: HTTP/1.1 with `Content-Length`, `413 Content Too Large` and a closed connection; HTTP/1.1 chunked, `400 Bad Request` (or 413) and a closed connection; h2c, the stream reset (`ENHANCE_YOUR_CALM`) and the connection kept. A client still sending can see a reset after the answer. The `Server` keeps serving.
- Not `FromBytes.max_bytes` or `Json[T]`'s 1 MiB: those are `App.handle`'s 413 on a body already received, through middleware. Over HTTP/1.1 the status alone does not tell which refused.
- It bounds one request body's buffer, not the server's memory (connections, streams, headers and slow clients are Flare's defaults). It is not denial-of-service protection in general and not authentication: any client can send up to the limit, received in full before middleware runs. It is per `Server`, not per route.

## Idle timeout

`idle_timeout_ms` is how long Flare keeps a connection open while nothing arrives on it ([M3-047](../history/architecture-decisions.md#server-idle-timeout-decision-m3-047)): before the first byte, between keep-alive requests, between h2c frames (a stalled h2c body included), and while an HTTP/1.1 request head is incomplete. Past it Flare closes the connection with no answer.

```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, idle_timeout_ms=30_000)
    server.serve(app)
```

- Default 500; 1 to 86,400,000 (one day). 0 is refused, since Flare would read it as no timer. A value shorter than a client's pause closes that client's connection.
- It does not bound an HTTP/1.1 body that is arriving (Flare's 30 s body timer), a response being written (5 s), or a handler. It does not let another request run while a handler runs; it decides whether waiting requests are answered afterwards or dropped.
- **Cost: every idle connection holds a file descriptor and a little memory (about 1.5 to 3 KB measured on Linux) for up to this long, and nothing caps how many.** Choose the shortest value that covers your slowest handler plus your clients' idle time.

## Request header field limit

`max_header_fields` is the most header fields a request may carry ([M3-066](../history/architecture-decisions.md#request-header-conversion-decision-m3-066)). A request with more is answered `431 Request Header Fields Too Large` by the adapter, before `App.handle` and middleware, on any path (only the missing-`Host` 400 comes first).

```mojo
def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind("127.0.0.1", 8080, max_header_fields=50)
    server.serve(app)
```

- Default 100; 1 to 65,535.
- It counts the fields as Flare hands them over, `Host` included; over h2c `:authority` counts as one `Host` field and every `cookie` field together as one. Every worker and a TLS `Server` apply it.
- Cost of raising it: the adapter's conversion grows with the square of the field count, and every `Headers.get` scans every field. Raise it only for a client that needs more. It bounds the fields Muntin converts, not the bytes Flare parses first.

## HTTPS

With `tls=Tls(cert_file=..., key_file=...)` the `Server` serves the same `App` over TLS instead of cleartext, every route, middleware, setting, worker and the stop unchanged ([M3-051](../history/architecture-decisions.md#server-tls-decision-m3-051); `examples/hello_https.mojo`):

```mojo
from muntin_flare import Server, Tls

var server = Server.bind(
    "0.0.0.0",
    8443,
    tls=Tls(cert_file="cert.pem", key_file="key.pem"),
)
server.serve(app)
```

- `Tls(*, cert_file: String, key_file: String)`: the certificate in PEM followed by any intermediates (the chain a client needs), and an unencrypted private key in PEM (PKCS#8 or the older RSA or EC form). Each file is at most 1 MiB.
- Start-up errors, raised by `bind` naming the file, before anything is bound: `TLS certificate file cannot be read: <path> (<reason>)`, `TLS key file cannot be read: ...`, `TLS certificate file is empty: <path>`, `TLS certificate file is larger than 1048576 bytes: <path>` (and the key file's), `TLS certificate file has no PEM certificate (-----BEGIN CERTIFICATE-----): <path>`, `TLS key file has no PEM private key: <path>`, `TLS key file holds an encrypted private key, which is not supported: <path>`. These are a best-effort diagnosis. When Flare cannot load the pair afterwards (a damaged block, a key that does not match), `bind` raises `TLS certificate or private key could not be loaded: <cert_file>, <key_file>`, naming no cause; on a port in use the address error comes first.
- OpenSSL reads the files again from their paths after Muntin's check: replace them before `bind`, not during it. Replacing them after `bind` changes nothing until the process binds again.
- Protocols: ALPN offers `h2` then `http/1.1`; a client that offers neither is served HTTP/1.1 (RFC 7301 says the server SHALL refuse; this is Flare v0.12.0's behavior). TLS 1.2 or later with Flare's forward-secret ciphers. The port serves TLS only; cleartext and HTTPS together take two processes.
- `idle_timeout_ms` also bounds each pause in a handshake, not the whole handshake; there is no handshake deadline.
- Flare ignores SIGPIPE in the whole process once `bind` is given `tls`, if its disposition is still the default.
- Not provided: automatic certificates or renewal, reload while serving, client certificates (mTLS), choosing versions, ciphers or ALPN, HTTP/3.

## Stopping

While `serve` runs, SIGTERM and SIGINT ask it to stop ([M3-045](../history/architecture-decisions.md#graceful-shutdown-decision-m3-045)). **Graceful means a bounded wait, not a cancellation**: Muntin cannot notify or cancel a running handler.

1. New connections are refused at once (the listener closes within about 50 ms on Linux and 200 ms on the macOS CI runner).
2. The open connections are served for `shutdown_grace_ms` (default 5,000; 0 to 86,400,000). The whole window is always waited, even with nothing in flight.
3. Flare closes every connection still open and `serve` returns; a `main` that does nothing after it exits with status 0.
4. **If the server has not stopped one second after the window** (a handler still running), **the process ends** with POSIX `_exit` and status 128 + the signal (143 for SIGTERM, 130 for SIGINT). Destructors, `atexit` handlers and buffered standard output are skipped, and requests still running get no answer; with workers, one held handler ends every worker's requests.

- Promised: a request whose handler is running when the signal arrives is answered if it returns and its response is written within the window. The process ends within the time to see the signal, the window and one second, whatever clients do (under the scheduling the tests see; a supervisor that needs a hard deadline still kills).
- Not promised: a request still being received or a response still being written when the window ends is cut. A request sent on an open keep-alive connection or h2c stream during the window is answered, but the response says `Connection: keep-alive` and h2c sends no `GOAWAY`; clients must retry idempotent requests on a closed connection.
- **What this asks of an application**: a handler can be stopped between any two steps, so make each change that must not be left partial atomic (a transaction, a write then rename). A handler can also finish its work and be stopped before its answer is written, and the client may retry: an idempotency key stored under a unique constraint in the same transaction keeps a retry from repeating a database change; an effect outside that database (a payment, an email) needs more coordination, such as an outbox.
- A second SIGTERM or SIGINT once the stop has begun ends the process at once (Ctrl-C twice), except as process 1 of a container without an init (`docker run` without `--init`), where it is ignored.
- There is no stop call: a program stops its own server by sending itself a signal (`kill(getpid(), SIGTERM)`).
- During `serve` the signals are stop requests whatever the process inherited, an ignored SIGINT included; `serve` puts back the previous handlers when it returns or raises. An application handler installed for them while serving disables the graceful stop. The thread that calls `serve` must not block SIGTERM or SIGINT. If installing or restoring the handlers fails, `serve` raises.
- Deploying: take the process out of the load balancer before sending SIGTERM, and let the supervisor wait longer than `shutdown_grace_ms` plus one second before it kills (Docker's 10 s and Kubernetes' 30 s defaults exceed the default 6 s).
