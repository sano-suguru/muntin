# Guarded routes and request context decision (M3-080)

> **Current.** Not built yet: its "Next production slice" is M3-081.

Status: **decision** (M3-080, #183, issue [#151](https://github.com/sano-suguru/muntin/issues/151)). Evidence and review: the pull request.

**Question.** Middleware cannot read start-up values ([M3-034](m3-034-middleware-decision.md)) or hand a handler the user ([M3-065](m3-065-request-context-storage-decision.md)), so the notes application (#167) authenticates in every handler. Which shape checks once, with start-up values, for some routes, before their conversions, and hands each a typed user? Settled on that application, under AddressSanitizer, by must-not-build fixtures and against [M3-052](m3-052-registration-complexity-budget-decision.md).

**Choice: a `Group` of routes behind one guard, mounted into the `App`.**

```mojo
def authenticate(svc: State[Service], headers: Headers) raises ApiError -> User: ...
def get_note(svc: State[Service], user: User, id: Int) raises ApiError -> Json[NoteJson]: ...

var notes = Group(authenticate, svc)
notes.get["/notes/{id}"](get_note, svc)
app.mount(notes^)
```

- The guard runs after 404, 405 and percent-decoding, before type conversions and the body; its raise answers as a handler's, ahead of a decoding 400.
- A handler, raw ones included, whose first request parameter has the guard's type `C` receives the value, moved; one without it is still guarded. `C` is a slot the group fixes, so no overload is added. It passes [M3-074](m3-074-state-borrowing-decision.md)'s name filter, which fixtures watch: no proof that `C` owns its data.
- Never stored: guard, its state and handler share one route box.
- `App` is `Group`'s generic type without a guard: the forty overloads serve both, `App` stays concrete ([M3-001](m3-001-application-state-decision.md)'s B1), and routes, middleware and dispatch sit in a non-generic part `Next` points to.

**Rejected.**
- `App[Ctx]` alone: public and protected routes share one guard, which needs a rule to tell them apart.
- A check per registration: a third overload family, past M3-052.
- The guard as a slot kind: a handler that omits it is unguarded.
- Storage keyed by type, or a value carried by `Next`: M3-065, M3-063.
- `app.use(f, state)`: stays in #150.

**Revisit when** a guard needs the method, the path, no state or to precede decoding, or groups nest or take middleware (each its own decision); or a handler needs the context and three slots (M3-052's ceiling).

**Next production slice (M3-081): guarded groups.**
- Code: `app.mojo` as prototyped, one shared helper per arity replacing each overload's second branch, a message naming `C` where it is not first; exports `Group`.
- Tests via `TestClient` under `SANITIZE=address`, counting live `C` and states: the pull request's cases, each of the eight guarded adapters with and without `C`, route-value records, a guard state unlike the handlers', a failed conversion without `C`, a guard that makes `C` then raises; a must-not-build fixture per refusal; the whole-output fixture comparison.
- Docs: a reference section, the guide's authentication case, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
