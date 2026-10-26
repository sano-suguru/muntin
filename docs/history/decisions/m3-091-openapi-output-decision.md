# OpenAPI and schema output decision (M3-091)

> **Current.** Not built yet: its "Next production slice" is M3-092.

Status: **decision** (M3-091, issue [#142](https://github.com/sano-suguru/muntin/issues/142)). Evidence: its pull request, [#202](https://github.com/sano-suguru/muntin/pull/202).

**Question and what settles it.** An application keeps its OpenAPI document by hand, a second copy of its routes and types; since [M3-082](m3-082-derived-json-codecs-decision.md) a `JsonFields` struct's JSON form is a function of its fields. Through what API does an application get the document, what does it say for each slot, result and codec without claiming what `App.handle` does not do, what does it do with routes OpenAPI cannot hold, and what does it cost an application that never asks? Settled by a scratch copy of production through `check.sh`, `test.sh`, `check_flare.sh` and a spike under AddressSanitizer, its document through an OpenAPI 3.1 validator and its exchanges against it; build costs; a fresh-context review.

**Choice: `app.openapi(title=, version=)`, the OpenAPI 3.1 document as JSON text, each operation written from the handler's types by a function its route stores.**

- A path item per route path, in registration order. Route values are parameters named by the placeholders: `Int` an `int64` integer, `String` and a `FromRouteValue` a non-empty string; a query value is required unless `Optional`.
- A `Json[T]` body, bare or carried, is `application/json` with the schema of what the derived reader takes; a text body is `*/*` string, a binary one `*/*`. A text result is `200`; a `Json[T]` result `2XX` (its status is chosen at run time; Muntin's own answers are never 2xx) of what is written; any other result an undescribed `default`.
- Schemas are inline, by `JsonFields`' rules; a hand-written direction is `{}`. Looser than the reader where JSON Schema cannot say it (`1.0` as an `Int`, duplicate names, depth, size). Not described: a `Json` answer of another status, Muntin's own answers, middleware, guards, header fields, raw input.
- It raises, naming the route, for a placeholder repeated in a path, two paths that differ only in names, and a query key or static segment common clients do not send as written.
- Nothing runs until `openapi` is called; every registration links its operation (binaries +6–8 %).

**Rejected.**
- Components named by reflected type names: names can collide (M3-063), and read and written schemas differ.
- A schema a hand-written codec declares: a copy that drifts, which #142 waited to avoid.
- `default` for a `Json[T]` result: it also covers Muntin's 400, 413, 415 and 500.
- `Json[T, status=201]`: a type every returning handler repeats (M3-089).
- Operations computed at compile time: 12–41 % less growth, not none; only an opt-in would remove it.
- Names normalized instead of a raise: a document whose names no route has.
- Code generation: as M3-082.

**Revisit when** Mojo reflects a function's name or docstring; applications need named components, `servers`, `security` or descriptions (a way to amend the document); a result's status is known at compile time; a hand-written codec needs a schema; or the size matters to applications that never call `openapi`.

**Next production slice (M3-092):** the prototype at `1c89cf0` (its `prototype-m3-091/README.md`).
- Code: as prototyped; `_registration_rules.mojo`'s docstring names `_document` among the grammar's users.
- Tests: `tests/test_openapi.mojo`: each slot, body, result and field kind's exact output, both directions, each refusal; its fixture with a revisit index row; mutations (`minLength`, `2XX`, `_carries_bytes`, an `Optional` member required on a read, each refusal and character class); the pull request's validator run.
- Docs: a reference page whose example serves the document through `State`, the guide, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
