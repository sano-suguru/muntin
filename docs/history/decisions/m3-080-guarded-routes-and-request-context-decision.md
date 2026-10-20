# Guarded routes and request context decision (M3-080)

> **Current.** Not built yet: its "Next production slice" is M3-081.

Status: **decision** (M3-080, pull request #183; issue [#151](https://github.com/sano-suguru/muntin/issues/151); `src/muntin` unchanged). The prototype, spikes, sanitizer runs and review are in the pull request.

**Question and what settles it.** The notes application (#167) authenticates in every handler: middleware cannot read start-up values ([M3-034](m3-034-middleware-decision.md)) or hand a handler the user ([M3-065](m3-065-request-context-storage-decision.md)), and applies to every route or none. Which shape writes that check once, with start-up values, for a group of routes, before their conversion, and hands each handler the user as a type both share statically: `App[Ctx]`, a typed group that borrows nothing, or a check at each registration? Settled by each on the notes application, soundness under AddressSanitizer and must-not-build fixtures, cost against [M3-052](m3-052-registration-complexity-budget-decision.md), and the choice on a scratch copy of production.

**Choice: a `Group` of routes behind one guard, mounted into the `App`.**

```mojo
def authenticate(svc: State[Service], headers: Headers) raises ApiError -> User: ...
def get_note(svc: State[Service], user: User, id: Int) raises ApiError -> Json[NoteJson]: ...

var notes = Group(authenticate, svc)
notes.get["/notes/{id}"](get_note, svc)
app.mount(notes^)
```

- The guard runs for every route of the group after 404 and 405, before any route value or body is converted (401 before 400); its raise answers as a handler's.
- A handler whose first request parameter, raw handlers included, has the guard's result type `C` receives the value, moved; a handler without one is still guarded. This second injected kind ([M3-001](m3-001-application-state-decision.md)) adds no overload: it is a slot whose type the group fixes. `C` owns its data ([M3-074](m3-074-state-borrowing-decision.md)'s rule) and is no slot kind.
- The value is never stored: the guard, its state and the handler share one route box, so M3-065's storage question does not arise.
- `App` names the guardless instantiation of the generic type `Group` is, so the forty overloads serve both and `App` stays concrete for backends (M3-001's B1). The routes, middleware and dispatch stay in a non-generic part that `Next` points to. Middleware stays `App`-wide. Cost: the prototype adds about 1,100 lines to `app.mojo`.

**Rejected.**
- `App[Ctx]` alone: one context for every route, so an unprotected route needs an optional value the handler checks.
- A check at each registration: a third overload family, past M3-052's budget.
- The guard as a slot kind: a handler that leaves it out is unguarded.
- Open storage keyed by type, or a value carried by `Next`: M3-065, M3-063.
- `app.use(f, state)` here: the guard covers authentication; configured middleware stays in issue #150.

**Revisit when:**
- an application needs the method or path in a guard, a guard without state, nested groups or per-group middleware: each its own decision;
- a handler needs the context and three other slots: M3-052's ceiling.

**Next production slice (M3-081): guarded groups.**
- Code: `app.mojo` as prototyped in the pull request, with a shared helper per arity instead of each overload's second branch, and a message naming `C` where it appears but first. Exports `Group`. Tests and fixtures that name `_routes` reach it through `_core`.
- Tests: the pull request's notes, raw-handler and admit-everyone cases through `TestClient`, with live counts of `C` and the guard's state, under `SANITIZE=address`; a must-not-build fixture per refusal; the whole-output fixture comparison against the base (`docs/DEVELOPMENT.md` section 3).
- Docs: a reference section, the guide's authentication case, `docs/ARCHITECTURE.md` (registration surface, request handling, storage and ownership), `docs/SPEC.md`.
