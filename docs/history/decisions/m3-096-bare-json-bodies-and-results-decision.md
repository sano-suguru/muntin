# Bare JSON bodies and results decision (M3-096)

> **Current.** Not built yet: its "Next production slice" is M3-097.

Status: **decision** (M3-096, issue [#194](https://github.com/sano-suguru/muntin/issues/194)). Evidence: its pull request. Changes part of M3-014, the M3-015 amendment, M3-080 and M3-082 (below).

**Question and what settles it.** Can a JSON handler name only its DTOs (`body: CreateUser`, `-> List[User]`) instead of `Json[...]`? What marks the body as JSON, do `Json[T]`'s rules apply, and what of a type that is also another kind, or of `List`, which cannot gain a conformance? Settled by a prototype on Mojo 1.1.0 and a fresh-context review.

**Choice: a `JsonFields` struct, or a `List` of one, is JSON as a bare body or result.** The owner chose this scope over the struct alone and over a deferral.

- The signal is the type's declaration, `JsonFields`, as a `FromBody` type's does.
- A bare body takes `Json[T]`'s steps and defaults (415, 413 over 1 MiB, the 400s); a bare result is 200 `application/json`. Another status or limit, an `Optional` or another `List` stays `Json[T]`.
- No conformance: `_kind` takes the bare body and `_respond` the bare result, as for `String`. Every overload's result clause gains `conforms_to(R, JsonFields) or conforms_to(R, Iterable)`; `_rule` narrows `Iterable` to a `List` of one before any `StaticString` test. No overload is added.
- Refused at registration: a bare JSON type that is also a `FromBody`, `FromBytes`, `FromRouteValue` or `RouteValues`; a result that is also a `ToResponse`.
- A Group's context cannot be a bare JSON type, now a body: its own message says to wrap it (`struct Authed: var user: User`).

**Rejected.**
- The struct alone: `List[User]` keeps the wrapper to save a clause branch.
- A deferral: the wrapper and `.value` stay in every JSON handler.
- `JsonFields` refining `ToResponse` with a default `to_response`: undocumented ([M3-082](m3-082-derived-json-codecs-decision.md)), and `List` still needs the clause.
- Exempting a Group's context (the owner's choice): with a `User` context, a handler's `body: User` would get the context, not the body.
- Preferring the bare type over its other conversion: the route's format would hang on a conformance far from the handler.

**Changes.** [M3-014](m3-014-registration-structure-decision.md)'s result rule is no longer the clause alone. The [M3-015 amendment](m3-015-registration-structure-amendment-generic-forwarding.md)'s "whole clause" has five branches: a helper copying the old three no longer builds, a break the routing reference must state with its migration. So does [M3-080](m3-080-guarded-routes-and-request-context-decision.md)'s guard returning a `JsonFields` struct (above), for the groups reference. M3-082's revisit condition "a bare DTO body" is answered.

**Revisit when** `where` clauses can call functions; a string slice becomes `Iterable` (then the `immutable_origin_result_*` messages change); `List` results need a status; or `WithHeaders` needs a bare JSON body.

**Next production slice (M3-097):** the prototype at `59959f7` (its `prototype-m3-096/README.md`).
- Code: as prototyped, without "(M3-096)" in the Group message, and the comments it left (the clause, `_respond` and `Group.__init__` in `app.mojo`, `_Route.json`, `_kind`, `_rule`).
- Tests: the spike's cases in the JSON suites, every shape and method, a guarded and a raw route beside them; its fixtures, and one for a `List` context beside `group_context`, with a revisit index row; `test_registration.mojo`'s whole-clause helpers.
- Docs: bodies, responses, routing, groups, OpenAPI, guide, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
