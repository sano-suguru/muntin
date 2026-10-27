# OpenAPI and schema output decision (M3-091)

> **Current.** Built by M3-092, changed in part by [its amendment](m3-092-openapi-output-amendment.md): overlapping paths and `%2e` dot segments raise, `parameters` additions are appended. Now described in [OpenAPI reference](../../reference/openapi.md).

Status: **decision** (M3-091, issue [#142](https://github.com/sano-suguru/muntin/issues/142)). Evidence: its pull request, [#202](https://github.com/sano-suguru/muntin/pull/202).

**Question and what settles it.** An application keeps its OpenAPI document by hand, a copy of its routes; since [M3-082](m3-082-derived-json-codecs-decision.md) a `JsonFields` struct's JSON form is a function of its fields. Through what API does an application get the document, what does it say without claiming what `App.handle` does not do, how does the application add what types cannot say, and what does an application that never asks pay? Settled by a scratch copy of production through the checks and a spike under AddressSanitizer, its document through an OpenAPI 3.1 validator and every exchange it sent against it, its guard's credentials too; sizes; adversarial reviews.

**Choice: `app.openapi(title=, version=, document=, operations=)` under `-D MUNTIN_OPENAPI`, the OpenAPI 3.1 document as JSON text, each operation written from the handler's types.**

- Route values are parameters: `Int` an `int64` within `Int`'s bounds, `String` and a `FromRouteValue` a non-empty string; an `Optional` query value is not required and has `allowEmptyValue` (empty is `None`).
- A `Json[T]` body is a required `application/json` body of what the reader takes; a text or binary body is an optional `*/*`. A text result is `200`; a `Json[T]` result `2XX` of what is written (Muntin's own answers are never 2xx); any other an undescribed `default`. Schemas are inline; a hand-written direction is `{}`; looser than the reader where JSON Schema cannot say it (`1.0` as an `Int`, duplicate names, depth, size). A `Json` 204 carries a body; a bodiless one is a `Response`.
- The application adds the rest as JSON objects: `document`'s members at the top level (`servers`, `security`, `components`; `info`'s into `info`), `operations["GET /notes/{id}"]`'s into that operation (`security`, `summary`, a response of another status, which takes precedence over `2XX`). One that names no route or repeats a derived member raises.
- It raises, naming the route, for a placeholder repeated in a path, two paths that differ only in names, and a query key or static segment common clients do not send as written (`%HH` is).
- Only a build with `-D MUNTIN_OPENAPI` links operations (binaries +9–12 %); without it, a call does not compile and other builds pay 0.8–1.7 %.

**Rejected.**
- Components named by reflected type names: they collide (M3-063); read and written schemas differ.
- A schema a hand-written codec declares, or a typed builder for additions: a copy of OpenAPI's vocabulary that drifts.
- `default` for a `Json[T]` result: it also covers Muntin's 400, 413, 415 and 500.
- `Json[T, status=201]`: a type every returning handler repeats (M3-089).
- Always linked operations, or computed at compile time (12–41 % less growth): every application pays.
- Names normalized instead of a raise: a document whose names no route has.
- Code generation: as M3-082.

**Revisit when** Mojo reflects a function's name or docstring; a group needs additions for all its routes (its guard's `security`); a result's status is known at compile time; a hand-written codec needs a schema; or applications need named components derived.

**Next production slice (M3-092):** the prototype at `a7070ad` (its `prototype-m3-091/README.md`).
- Code and scripts: as prototyped; `_registration_rules.mojo` names `_document` among its users.
- Tests: `tests/test_openapi.mojo`: each slot, body, result and field kind's exact output, each addition and refusal; the fixtures with a revisit index row; mutations (`minLength`, `2XX`, `allowEmptyValue`, `_carries_bytes`, the derived-member check, each refusal and character class); the validator run.
- Docs: a reference page whose example serves the document through `State`, the define in `docs/DEVELOPMENT.md`, the guide, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
