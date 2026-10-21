# Request context decision (M3-063)

> **Withdrawn** by [M3-065](m3-065-request-context-storage-decision.md). Its other part, the owning `App.handle` (M3-064), shipped and holds. The context over a closed type is [M3-080](m3-080-guarded-routes-and-request-context-decision.md)'s guarded groups. Now described in [testing reference, "The backend seam"](../../reference/testing.md#the-backend-seam) and [ARCHITECTURE, "Backend seam"](../../ARCHITECTURE.md#backend-seam).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-063, pull request #113; `src/muntin` unchanged). The prototype, probes, reviews and measurements are in the pull request.

**Question and what settles it.** [M3-034](m3-034-middleware-decision.md) left middleware unable to hand a handler what it established (an authenticated user): header fields are client input, and a second injected kind doubles the overloads ([M3-001](m3-001-application-state-decision.md)). An outside review asked for that, type-safe, and for the cost of the request copy `App.handle` makes when middleware is registered (M3-034's last revisit condition). What public API should carry such a value, can Mojo 1.1.0 store it behind a non-generic `App` without ever restoring one type as another, and what should the copy become? Settled by: a scratch prototype on production (not retained) passing `check.sh`, `test.sh` and `check_flare.sh`; an adversarial review of it, which showed its type key unsound; probes of each type identity Mojo 1.1.0 offers (`tests/context_known_gaps/reflected_names_collide.mojo`); the copy timed by body size.

**Choice: fix the context's public API now, ship none of it until a storage that never restores a value as another type is shown sound, and build the owning `App.handle` on its own.**

```mojo
def auth(var request: Request, var next: Next) raises -> Response:
    var token = request.headers.get("authorization")
    if not token:
        return Response.text("unauthorized", status=401)
    request.context.set(CurrentUser(verified_name(token.value())))
    return next^.run(request^)


def me(user: Context[CurrentUser]) -> String:
    return user[].name
```

- The API the storage item builds: `Request.context` holds at most one value per type; `set(value^)` attaches or replaces, `get[T]()` is an `Optional[Context[T]]`. `Context[T]` is a read-only shared handle with `State`'s guarantees ([M3-004](m3-004-state-storage-decision.md)). A handler takes it as a request slot kind after `State` and before everything else: `State`, then `Context` slots, then route values (a route-value record included, [M3-061](m3-061-route-value-records-decision.md)), then a body or `Headers`. It binds no placeholder and adds no overload. A raw handler reads `req.context`.
- Only application code writes it: `Request` starts it empty and no backend or Muntin step adds to it, so, unlike a header field, it can carry what a middleware established. It is a data carrier, not authentication or authorization: a middleware that cannot establish the value answers itself (401, 403) before `next`.
- No value of the slot's type is the fixed 500, the handler not called: the middleware did not establish what the registration assumes, an application fault. The response names nothing; Muntin reports the type and the route internally, with dropped handler errors.
- Storage is open. Behind a non-generic `App` a value is erased, and Mojo 1.1.0 documents no type identity to restore it by; erasure also drops a value's origins, which the storage must refuse or bound.
- `App.handle(self, var request: Request)` beside the borrowing one: Mojo 1.1.0 picks it for a temporary or `request^`, the borrowing one for a named value. With middleware it hands the request to the first middleware; the borrowing one copies, as today. Not zero-copy: the Flare adapter still copies the body out of Flare's request, and a raw handler still receives a copy of the body (M3-040). The copy measured +2 µs at 64 KiB, +49 µs at 1 MiB and +0.79 ms at 10 MiB per request, against about 155 ns of dispatch.

**Rejected.**
- Keying by `reflect[T].name()`: distinct types print alike (origins, function values), and a restore under a shared name overflowed the heap; refusing names with `{` or `<` bans today's known collisions only, and a size and alignment check is no type check.
- Keying by the address of a function specialized on the type: specializations with equal bodies share one address, at `-O0` and `-O3`.
- Keying by `get_linkage_name`: tells value parameters apart but not origins, and is a symbol name, not a documented identity.
- `Context` as a second injected argument family: doubles the overloads (M3-001, [M3-052](m3-052-registration-complexity-budget-decision.md)).
- String locals read by key and converted in the handler: a misspelled key is a 500 at run time, and every value is reparsed.
- A handler-side extractor: nothing passes from middleware, and leaving the parameter out skips the check; it stays [M3-054](m3-054-application-route-value-types-decision.md)'s carrier revisit.
- A value carried by `Next`: later middleware and raw handlers cannot read it.
- `T` delivered by copy: needs `Copyable` and copies per handler.
- `App.handle` taking only `var request`: every caller with a named request would need `^` or `.copy()`, an M2 seam change.
- `Request.body` as a shared buffer: reopens M3-040's public type for a copy the overload removes.

**Revisit when:**
- the storage item finds only a closed set of context types sound (`App[Ctx]`, a table fixed at registration): decide this API again with it;
- Mojo documents a type identity, or `tests/context_known_gaps/reflected_names_collide.mojo` stops building: the storage item re-measures it;
- a handler needs a value that may be absent: decide an `Optional` slot then;
- a shape needs a `Context` with two route values and a body or `Headers` (slot arity 4): M3-052's ceiling decision;
- per-route middleware is decided: whether registration can check that a route's middleware attaches what its handler needs;
- a backend cannot hand over its request: it keeps the borrowing `handle` and its copy.

**Next production slice (M3-064): the owning `App.handle`.**
- Code: `app.mojo`: `handle(self, var request: Request) -> Response` beside the borrowing one; with middleware it moves the request into the chain, without it both answer through the same dispatch. `TestClient` and the Flare adapter move their requests into it. No `Context`.
- Tests: in `tests/test_middleware.mojo`, the owning and the borrowing `handle` answer alike for each middleware case; with middleware, the first middleware receives the caller's body buffer (the same address), through the owning one only. The adapter's loopback middleware cases, over HTTP/1.1 and h2c, pass unchanged.
- Measure: the pull request's copy timing again, with middleware, through the owning `handle`: flat across body sizes.
- Docs: `docs/DX.md` sections 7, 11 and 15; `docs/ARCHITECTURE.md` (request handling, Request/Response ownership); `docs/SPEC.md`.
- Not in the slice: `Context`, the adapter's body copy, a raw handler's body copy.
