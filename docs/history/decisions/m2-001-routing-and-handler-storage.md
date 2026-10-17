# Routing and handler storage (M2-001)

> **Current.** Now described in [routing reference, "Matching"](../../reference/routing.md#matching), [routing reference, "Route literals"](../../reference/routing.md#route-literals) and [route-values reference, "`Int` values"](../../reference/route-values.md#int-values).
> Changed in part since:
> - [M2 handler storage decision](m2-handler-storage-decision.md): the Variant handler storage was replaced by the private typed box (implemented in M2-004).
> - [M3-018](m3-018-route-value-decoding-and-string-route-values-decision.md): captured segments are now percent-decoded once (was: not decoded).
> - [M3-026](m3-026-head-decision.md): a get route also answers HEAD.
> - [M3-030](m3-030-method-not-allowed-decision.md): no match is 405 with Allow when another method's route matches the path (was always 404).
> - [M3-053](m3-053-route-conflict-decision.md): first-match order no longer depends on registration order alone: overlapping registrations that are not most-specific-first abort.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

`App` stores each route as method, the route literal's path part (plus a query key since M2-002), and the handler: a `Variant[def() thin -> String, def(Int) thin -> String]` until M2-004, now a private typed box ("Production implementation (M2-004)" below). `App.get` is overloaded on those two shapes (each with a `ToResponse` twin since M2-008), so `app.get["/hello"](hello)` and `app.get["/users/{id}"](get_user)` are the same call syntax and both take the handler as a runtime value. `App.handle` scans routes in registration order; the first route whose method and segments match handles the request (later matches are not tried, even if conversion fails). A static segment matches by byte equality; a `{name}` segment matches one non-empty segment. For an `Int` handler, Muntin converts the captured segment (optional `-`, ASCII digits, `Int` range) before calling the handler; anything else returns 400 `Bad Request` and the handler is not called. No match is 404. Routing and extraction run only inside `App.handle`: `TestClient` and the Flare adapter pass the request target through unchanged and have no knowledge of `{name}`. Matching uses `Request.path`, which since M2-002 excludes the query (next section). Percent-encoded segments are not decoded.

Until M2-004, `App.handle` selected the arm with `isa` for each shape and aborted on an unhandled one; since M2-004 each `App.get` overload pairs the handler with its adapter at registration and dispatch is one call, so there is no per-shape branch. `App.get` checks the route literal at compile time with the same segment classifier the runtime matcher uses (`_is_param`): a malformed literal, or a parameter count that differs from the handler's arity (0 or 1), fails to compile at the registration call. Because both use one classifier, an `Int` route always captures exactly one segment at runtime.

Storage choice, compared on Mojo 1.1.0:

| Mechanism | Unsafe | Heterogeneous shapes | Cost |
|---|---|---|---|
| `Variant` of thin function types (M2-001 to M2-003; replaced in M2-004, see "Handler storage decision (M2)") | no | closed set; each shape is one arm, checked with `isa`/`[]` | new handler shapes or return types each need an arm; `-> String` only today |
| Address-bits erasure + trampoline (M0.5 prototype) | yes (`Pointer.unsafe_bitcast` of a function value to `Int`) | open over return types | relies on undocumented function-value representation; not adopted |
| Handler as compile-time parameter | no | open | public syntax becomes `app.get["/users/{id}", get_user]()` |
| Capturing closures, `rebind`, non-`thin` function fields | — | do not compile (diagnostics in `docs/DX.md`) | — |

The `Variant` held plain function values: no heap context, no captured state, no lifetime tied to the `App` beyond the `List` that owns the routes. Moving an `App` moves its route list; copying a route copies its function value; nothing is reinterpreted. The M0.5 unsafe storage therefore did not enter `src/muntin`; it remains only in `tests/test_spike_handler_model.mojo` as the record of the comparison. More Muntin-known parameter or return types grow the closed set; an application-defined type (`-> User`, `body: CreateUser`) cannot be an arm at all. The M2 storage decision below replaced this storage (M2-004) before any new handler shape.
