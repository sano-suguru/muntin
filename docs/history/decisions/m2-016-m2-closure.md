# M2 closure (M2-016)

> **Current.** Now described in [M2 completion contract](../m2-completion-contract.md#m2-completion-contract) and [M2 completion contract, "When M2 reopens"](../m2-completion-contract.md#when-m2-reopens).
> Changed in part since:
> - [M3-014](m3-014-registration-structure-decision.md): the registration overloads were changed under its reopen rule (the contract lists this as an amendment by M3-015).
> - [M3-026](m3-026-head-decision.md): contract reopened: HEAD answered by get routes.
> - [M3-030](m3-030-method-not-allowed-decision.md): contract reopened: 405 with Allow instead of 404.
> - [M3-039](m3-039-request-target-and-method-bytes-decision.md): contract reopened: a non-UTF-8 method or target is the adapter's 400.
> - [M3-040](m3-040-binary-request-and-response-bodies-decision.md): contract reopened: Request.body and Response.body are bytes.
> - [M3-053](m3-053-route-conflict-decision.md): contract reopened: conflicting registrations abort (evidence quoted from docs/history/m2-completion-contract.md).
> - [M3-073](m3-073-request-host-decision.md): contract reopened: a request without Host is the adapter's 400.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision**; product behavior is unchanged (no change under `src/muntin` or `adapters/`, and no test or fixture changes). **M2 is complete.** The contract's guarantees are in `docs/SPEC.md` ("M2 completion contract"); its list of what M2 deliberately left out is in git history, and current limits are in `docs/ARCHITECTURE.md`. This section records how the decision was reached.

**Question.** Does the merged implementation satisfy M2's boundary, typed application ergonomics, well enough to close the milestone? Or is there exactly one missing capability without which M2 cannot honestly be called complete? M2's boundary is the handler/application programming model, not feature breadth.

**Production shapes as of M2-015.** `App` has ten registration overloads, all with the syntax `app.<method>[route](handler)`:

| Method | Argument shape | Results | Errors |
|---|---|---|---|
| `get` | `def()`, `def(Int)` | `String`-compatible, or `R: ToResponse` | `thin raises E`, inferred: `Never`, `Error`, application `T` |
| `post` | `def(var B)`, `def(Int, var B)` with `B: FromBody` | `String`-compatible, or `R: ToResponse` | same |
| `get`, `post` | raw `def(var Request)` | `Response` | same |

**Every M2 item maps to merged behavior.**

| Item | Kind | Merged as | PR |
|---|---|---|---|
| M2-001 | production | one `Int` path value | #7 |
| M2-002 | production | path/query split in `Request`; one `Int` query value | #8 |
| M2-003 | decision | handler storage; slice M2-004 | #9 |
| M2-004 | production | move-only typed box `_Erased`, behavior unchanged | #10 |
| M2-005 | decision | argument extraction; slices M2-006, M2-009 | #11 |
| M2-006 | production | body-only `POST`, public `FromBody` | #13 |
| M2-007 | decision | typed response; slice M2-008 | #15 |
| M2-008 | production | public `ToResponse`, `Response` conforming | #16 |
| M2-009 | production | `POST` `(Int, B)` | #17 |
| M2-010 | decision | application errors; slice M2-011 | #18 |
| M2-011 | production | parametric `raises E`, fixed 500 | #19 |
| M2-012 | decision | error responses; slice M2-013 | #20 |
| M2-013 | production | public `ToErrorResponse` | #21 |
| M2-014 | decision | raw `Request` handlers; slice M2-015 | #22 |
| M2-015 | production | raw overloads on `get`/`post` | #23 |

Each decision's "Next production slice" was merged as the item it names, and no decision names a production slice that has not merged. Two scope notes: M2-005's positional rule covers several route values, but its only committed slices were body-only `POST` and, later, `(Int, B)`, both merged; several route values never had a slice. M2-014's revisit conditions (raw route values, broader raw results, `Request` fields) are conditions, not committed slices.

**The blocker test.** A deferred capability blocks M2 only if a statement that `docs/DX.md` labels proven or production, an M2 acceptance item in `feature_list.json`, or a rule in `.claude/rules/public-api.md` needs it, and its absence then breaks a promised core workflow, contradicts the documented public API, or leaves the typed/raw boundary materially incomplete. DX snippets labeled as targets or provisional do not count: they may be revised when they describe later work. Four candidates could plausibly fail this test, and each was checked (the fresh-context review added a fifth, state, recorded after the list):

1. **`app.run()`.** DX section 1, DX section 19 and the README use it. Each is labeled a target, and DX section 1's status line has said since M1 that public run/lifecycle ownership is undecided. No acceptance item requires it (SPEC M1 proved serving through Flare without it). The Flare policy above places server bootstrap and lifecycle in the adapter. Not a blocker; the contract says plainly that application code has no supported way to serve an `App`.
2. **Headers.** DX section 9 marks headers as a target. No proven statement reads or sets a header, and the public-api rule asks only that raw `Request -> Response` handling stay available. The raw handler receives every field Muntin's `Request` has, so the typed/raw boundary is complete for the current request model; typed and raw handlers lack headers alike. Not a blocker. DX section 9's motivation sentence listed uses that need headers without saying so; M2-016 corrects it.
3. **Non-`Int` dynamic segments.** `/users/{name}` with a `String` value cannot be routed by a typed handler (only `Int`) or by a raw handler (raw literals declare no placeholders). This is documented (DX "Still targets"; DX section 9: "The route literal declares no path or query parameter"), so it contradicts nothing. Not a blocker, but it is the most visible gap, and the contract names it explicitly.
4. **SPEC's M2 bullet "foundations for schema/OpenAPI generation".** This is the only item on SPEC's M2 exploration list with no delivered item or recorded decision. The list is exploration scope, not acceptance, and no feature item names it. M2's body and result contracts are format-agnostic (`from_body(String)`, `to_response`), so no type-level schema source exists until a codec defines one; `reflect[T].field_names()` works on Mojo 1.1.0 (DX, M2-002 facts), so nothing in M2 forecloses it. Moved to M3, together with "serialization" (M2 delivered conversion).

Fifth, **runtime data in handlers** (found by the review). On Mojo 1.1.0 module-level variables do not compile (`global variables are not supported`), handlers are thin functions that cannot capture, and there is no state API in M2, so a handler reads only its arguments and compile-time constants. The `users.get(id)` of DX sections 2, 4 and 19 and of the decision rule is therefore not expressible yet. Every one of those snippets is a target (DX section 8 marks state as a target); no proven example, acceptance item or public-api rule needs shared data. Not a blocker under the rule, but it is the property of the handler model that the contract names first. Application state is class 2, not 3.

**Classification of the deferred candidates.** The classes are: 1 = required for M2's existing promise to be truthful/coherent; 2 = useful but additive (M3 or later); 3 = outside M2's concern.

| Candidate | Class | Reason |
|---|---|---|
| public `app.run()` / lifecycle | 3 | serving belongs to backend/lifecycle work, not the handler model; DX labels it a target with undecided ownership; M3 "graceful lifecycle integration" |
| request/response headers | 2 | a new `Request`/`Response` field and seam translation; no proven statement needs it; second M3 item (M3-002) |
| JSON body/response | 2 | the codec fills `from_body`/`to_response` without changing routing or binding (DX section 4); needs headers for Content-Type |
| more HTTP methods | 2 | overload families repeating the `get`/`post` contract; nothing in the model is specific to a method except body-on-`POST` |
| more/non-`Int` route or query values | 2 | M2-005's positional rule covers them; each type adds a converter |
| optional/default query values | 2 | needs a representation proven against Mojo's reflection limits (DX section 3); additive |
| raw route values, broader raw results | 2 | additive overloads or route rules under M2-014's parameter-list invariant |
| application state | 2 | no proven statement needs it, but handlers can read no runtime data without it (no globals on Mojo 1.1.0, no captures), and DX section 8 makes it a handler parameter. This is the M3 item most likely to touch an M2 signature or M2-005's binding rule (reopen condition below), so it is the first M3 item (M3-001) |
| middleware | 3 | composition (SPEC M3); no M2 statement depends on it |
| logging/observability | 3 | M2-010 drops handler errors unread on purpose until a hook exists (SPEC M3) |
| application-level error mappers | 2 | M2-012 rejected them on Mojo 1.1.0 (heterogeneous storage, type identity or `App` coupling) and kept the per-type opt-in; its revisit conditions apply |
| schema/OpenAPI foundations, serialization | 2 | moved from M2's exploration list (item 4 above) |

No candidate is class 1.

**Recorded compiler limitations.** Neither blocks closure, because ordinary application code (a plain `def` handler passed by name) is unaffected:
- an explicitly typed non-raising function value needs `raises Never` (M2-011, `storage_fail/typed_thin_value_handler.mojo`);
- a raw function value must be typed `def(var Request) thin raises Never -> Response` (M2-015).

**Reopen M2 (rather than add an M3 item) when:**
- a toolchain upgrade changes what M2's contract rests on: overload resolution (`raw_fail/equal_parameter_lists.mojo` compiles), parametric raises inference, or `conforms_to` detection. Re-measure, and re-verify the contract before adding features;
- an M3 design has to change an M2 public signature or semantics instead of adding to them, for example a changed `Request(method, target, body)` initializer, a different 400/404/500 boundary, or `ToResponse`/`ToErrorResponse` becoming fallible. That is a breaking change to the contract and needs its own explicit decision;
- a statement that DX labels proven stops passing its test. That is a defect, to be fixed before new M3 work.

**Next.** M3-001, the application state decision gate, then M3-002, the request/response headers decision gate (`docs/SPEC.md`, M3). State comes first because it is the M3 item most likely to reopen this decision. Both are decision only; neither is implemented here. (M2-016 merged as PR #24. M3-001 is decided below, "Application state decision (M3-001)", and does not reopen M2.)
