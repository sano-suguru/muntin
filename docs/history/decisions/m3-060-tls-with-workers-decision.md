# TLS with workers decision (M3-060)

> **Current.** Now described in [serving reference, "Workers"](../../reference/serving.md#workers), [serving reference, "HTTPS"](../../reference/serving.md#https) and [ARCHITECTURE, "Flare adapter"](../../ARCHITECTURE.md#flare-adapter).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision and production** (M3-060, pull request #108; `src/muntin` unchanged). The Flare reading and the tests' observations are in the pull request.

**Question and what settles it.** [M3-049](m3-049-multi-worker-serving-decision.md) shipped workers and refuses a TLS `Server`; [M3-051](m3-051-server-tls-decision.md) shipped TLS on one reactor. An outside review pointed out that Flare v0.12.0 serves TLS on several workers, so Muntin's layer takes a capability away. Should `serve[make](workers=n)` serve a TLS `Server`, or keep refusing it and recommend terminating TLS in front of several cleartext workers? Settled by how Flare v0.12.0 runs TLS on its own workers (read in code), whether the adapter's workers and stop can do the same without changing any public signature, and real TLS connections on Linux and macOS showing a handshake on every worker, both protocols, no cleartext answer, and the stop.

**Choice: serve TLS on every worker with the `Server`'s one TLS context.** Flare's multi-worker `serve` hands every worker the address of the `HttpServer`'s one `ServerCtx` (`_tls_ctx_addr`; its comment: OpenSSL designs `SSL_CTX` for shared read-only use across threads, each connection gets its own `SSL`), and its per-worker loop, `run_unified_reactor_loop_shared`, the loop the adapter's workers already run, takes that address and starts every accepted connection as a TLS handshake. So the adapter passes the same address to each worker's loop, and the refusal goes. The context lives in the `Server`'s `HttpServer`, which `serve[make]` borrows mutably until every worker is joined, so it outlives every reader. Nothing else changes: the file checks and the load stay in `bind`, once, the workers' stop (parking the listener copies, the window) does not touch the context, and `serve(app)`, `Tls`, `Server.bind` and every signature are unchanged. What workers improve and what they do not (M3-049) holds over TLS as over cleartext; a TLS handshake also runs on its worker's reactor, so a held handler holds the handshakes of connections its worker has accepted. Terminating TLS in a proxy in front of cleartext workers stays a valid deployment, and is not required.

**Rejected.**
- Keep the refusal and document a TLS-terminating proxy as the way to serve TLS with workers: the review's point stands, Muntin's layer would serve less than Flare does, for a change of one argument.
- One context per worker, each loading the files: it repeats the load and the check-to-load gap per worker, and keeps per-worker session caches, for no isolation the shared read-only context lacks.
- Flare's own multi-worker `serve`: rejected by M3-049 (a `Copyable` handler, and its stop).

**Revisit when:**
- the Flare pin moves: `tls_context_addr` and `run_worker_loop` in `adapters/flare/flare_internals.mojo` rely on `HttpServer._tls_ctx_addr` and the loop's `tls_ctx_addr` argument; re-run `adapters/flare/test_tls.mojo`;
- certificate reload while serving is wanted (M3-051): replacing a context every worker reads needs a synchronized swap, a design question of its own;
- `adapters/flare/test_tls.mojo`'s workers tests change an observation (a TLS connection not handshaken while another worker is held, a cleartext request answered, a stop that does not return).

**Next production slice (M3-060, in this item).**
- `adapters/flare/flare_internals.mojo`: `tls_context_addr(server)` replaces `has_tls`, and `run_worker_loop` takes the address and passes it to Flare's loop. `adapters/flare/muntin_flare.mojo`: a worker-table cell holds it for each worker; the refusal and its message go.
- `adapters/flare/test_tls.mojo`, two workers on a TLS `Server`, replacing the refusal test: while one worker's handler is held on a TLS connection, new TLS connections are handshaken and answered by the other over HTTP/1.1 and HTTP/2 before the release, the held one is answered after it, and SIGTERM ends `serve` normally; a cleartext request is answered by no worker, during the hold and after it.
- Docs: `docs/DX.md` section 1 (Workers, HTTPS), `docs/ARCHITECTURE.md` (workers, TLS, revisit index), `docs/SPEC.md`, `README.md`.
