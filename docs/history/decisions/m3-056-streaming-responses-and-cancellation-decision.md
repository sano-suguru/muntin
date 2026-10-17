# Streaming responses and cancellation decision (M3-056)

> **Current.** Its slice (M3-057) has not been built: nothing is streamed yet (`docs/SPEC.md`, "Remaining candidates"). Now described in [ARCHITECTURE, "Current limits"](../../ARCHITECTURE.md#current-limits), [SPEC, "Remaining candidates"](../../SPEC.md#remaining-candidates) and [serving reference, "Stopping"](../../reference/serving.md#stopping).
> Changed in part since:
> - [M3-074](m3-074-state-borrowing-decision.md): the slice's erased stream-source box must apply the no-borrowing rule for erased values.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-056, pull request #101, which holds the Flare reading, the probe's observations, the storage spike and the owner's two reviews; `src/muntin` unchanged).

**Question and what settles it.** `App.handle(Request) -> Response` returns a whole body, so a handler cannot send a body it produces over time or one larger than memory, and cannot learn that the client has gone. An outside review asked to settle streaming responses and cancellation first; WebSocket, protocol-specific control and streamed request bodies are out of scope. Settled by: what Flare v0.12.0 delivers on the path `Server` serves (`HttpServer.serve` with a `Handler`; the same connection handles under the workers' loop), read in code and measured over loopback by `compat/flare/stream/stream_probe.mojo`; and whether Mojo 1.1.0 lets a `Copyable` `Response` carry a stream of an application type (a scratch spike).

**Facts** (Flare v0.12.0; measured unless marked read):
- A Flare `Response` holding a `ChunkSource` is sent with chunked framing over HTTP/1.1 (no `Content-Length`) and in DATA frames over HTTP/2, over TLS too (read). The source is pulled only when the connection is writable, at most 16 chunks or 64 KiB per writable edge (read): backpressure comes from the pull.
- A stream holds the reactor only during a pull: another connection is answered while a quiet stream is open, unlike a running handler ([M3-046](m3-046-head-of-line-blocking-decision.md)).
- A source with nothing to send returns an empty chunk and is pulled again on the next writable edge, a busy loop (780,490 pulls in 1.5 s, one stream, one Linux run); so the idle timer does not close a quiet stream. CPU use, and many quiet streams at once, are not measured.
- When the client goes away (HTTP/1.1 close, h2c connection close, h2c `RST_STREAM`), Flare stops pulling the source once it notices (a failed write or the reset), destroys it and never sets its `Cancel`; the server keeps serving. How many pulls fall between the client going and Flare noticing is not measured.
- A pull that raises ends the response after its status and fields: over HTTP/1.1 the connection closes without the last chunk, and the chunks pulled earlier in the same batch are lost; over HTTP/2 Flare closes the whole connection (read).
- `Cancel` reaches a handler only through `serve_cancellable` (HTTP/1.1, one thread, no TLS), and is never set while one runs: a peer close is acted on before the call, the handler timeout is "not enforced yet", and a drain sets it after the loop stops (read).
- Mojo 1.1.0: a `Copyable` struct can hold a type-erased, reference-counted box of a move-only source of any type, pulled through a borrowed handle and destroyed once, after its last handle, with unsafe operations of the kind `_Shared` already confines (spike).

**Choice: stream response bodies from a Muntin-owned pull source that `Response` carries; offer no cancellation API.**
- A Muntin trait, `BodySource`, with `def next(mut self) raises -> Optional[List[UInt8]]`: a chunk, an empty chunk for "nothing now", or `None` at the end. `Response.stream(source^, status=200)` builds a response with an empty `body`, that source and fields set as on any `Response`. For every backend, Muntin promises that a backend pulls a source only when it can send more, and never again once the source has returned `None` or raised, or once the backend has noticed that the client went away; a backend may pull after the client has gone and before it notices. A backend that ends a stream, for any reason, releases its handle, and the source is destroyed once, when its last handle goes.
- Destruction is cleanup, not a signal: it also follows a complete stream, a raise, `HEAD`, a response that middleware replaced or nobody sent, and a stop; it does not say which, and a remaining copy delays it. An application releases resources in the source's destructor and cannot learn from it that the client went away.
- The seam does not change: the stream travels inside the `Response` `App.handle` returns, through middleware. Copies of a streamed `Response` share one stream. Pulling consumes it: chunks a middleware or a test pulls with `next_chunk` are not sent. Pulls are not synchronized, so one stream is pulled by one caller at a time; a backend pulls on the worker that ran `App.handle`, and safe code has no way to hand a response to another worker (M3-049).
- A raise ends the response incomplete (the status has gone out, so no 500), and the error is dropped unread, as a handler's is. `HEAD` through a streamed `GET` route sends the status and fields with no content and no `Content-Length`, and the source is destroyed unpulled.
- Cancelling a running handler is not offered: no backend Muntin has can signal one, and a token that never fires is a promise Muntin cannot keep (A4).
- What an empty chunk gives: a stream with gaps (server-sent events) can be expressed without holding the worker. What it does not: an efficient wait. On Flare v0.12.0 a quiet source is a busy loop, so whether many long-lived event streams run at an acceptable cost is not established, and Muntin promises no such cost. Muntin adds no wakeup (A4, A6).

**Rejected.**
- Flare's `ChunkSource` or `Cancel` in application code: A1.
- A cancellation token in Muntin handlers: no path `Server` uses ever sets one; dead API.
- A move-only `Response`: reopens M2 (`Response` is `Copyable`).
- A second seam or handler kind for streams (`App.handle_stream`, a separate registration): routing, 404/405 and middleware would need a second path; `Response` can carry the stream.
- A push writer (the handler calls `write(chunk)`): the handler must keep running while the backend sends, which needs a task model (A6) or holds the reactor ([M3-046](m3-046-head-of-line-blocking-decision.md)).
- Data-or-end only (no empty chunk): a source that has to wait would wait inside `next`, holding every connection of its worker, worse than the busy pull.
- Flare's `serve_streaming`: raw bytes, no HTTP parsing, no TLS.

**Revisit when:**
- Flare sets `Cancel` while a handler runs, or wakes a quiet source instead of pulling it on every edge: re-run the probe on every Flare upgrade;
- Mojo ships an async model a backend runs handlers on: a handler-level cancellation and a waiting source without a busy loop may become expressible;
- streamed request bodies, WebSocket or trailers are taken up (the `Trailer` and `TE` fields: [M3-002](m3-002-headers-decision.md));
- `compat/flare/stream/stream_probe.mojo` changes its observations, or M3-057's measurement of quiet streams shows a cost the decision should not accept.

**Next production slice (M3-057):**
- `src/muntin`: `BodySource`, `Response.stream`, `Response.is_stream()` and `Response.next_chunk() raises -> Optional[List[UInt8]]` (the pull a backend, a middleware or a test makes; `None` on a buffered response); the erased shared box beside `_Shared` in `_handler_storage.mojo`, with `scripts/check_unsafe.sh` updated to allow it and nothing else.
- Flare adapter: `to_flare_response` hands a streamed response to Flare's `stream_response` through an adapter-owned `ChunkSource` that pulls the Muntin stream and ignores `Cancel`; the `HEAD` rule above in `_serve_app`.
- Evidence beyond `docs/DEVELOPMENT.md` section 3: an ownership oracle (one destruction, after the last copy, so a remaining copy delays it; destruction unpulled when abandoned; no pull after `None` or a raise), also under `SANITIZE=address`; middleware passing a streamed response on; loopback cases over HTTP/1.1 and h2c for chunk order, a client that disconnects (the source destroyed) and `HEAD`. A measurement, not a check, reported in the pull request: CPU use and the latency of a plain request with 1, 10 and 100 quiet streams open on one worker.
- `docs/DX.md` section 14 states the contract, its cost, that `next_chunk` consumes, and that destruction is not a disconnect signal; `docs/ARCHITECTURE.md` the representation.
- Not in the slice: streamed request bodies, an SSE event type or helper, WebSocket, a cancellation token, a wakeup, trailers, a `Content-Length` for a stream of known length.
