# Error-response decision (M2-012)

> **Current.** Now described in [errors reference, "Application error responses (`ToErrorResponse`)"](../../reference/errors.md#application-error-responses-toerrorresponse).
> Changed in part since:
> - [M3-058](m3-058-dropped-error-report-decision.md): a non-opted error is no longer dropped unread: the fixed 500 carries its report.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M2-012, merged as PR #20; production was unchanged in it); production implements it since M2-013 ("Application-defined error responses in production (M2-013)", below). This section decides whether and how an error a handler raises can produce an application-defined `Response` instead of the fixed 500, without changing what any handler that compiles today answers.

**Contract: per-error-type opt-in through a dedicated trait.** Muntin adds a public trait, separate from `ToResponse`:

```mojo
trait ToErrorResponse(Deinitable):
    def to_error_response(var self) -> Response: ...
```

and the one function every adapter already calls on a handler error decides per instantiation:

```mojo
def _handler_error[E: Deinitable](var e: E) -> Response:
    comptime if conforms_to(E, ToErrorResponse):
        return e^.to_error_response()
    else:
        return _internal_error()        # the fixed 500, as in M2-011
```

```mojo
@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def get_user(id: Int) raises NotFound -> User: ...
app.get["/users/{id}"](get_user)        # unchanged registration
# GET /users/0 -> 404 "no user 0"; GET /users/abc -> 400; GET /users -> 404
```

**Opt-in rule (supported contract).** A raised error converts if the handler's *declared* error type `E` (the `T` in `raises T`) declares conformance to `ToErrorResponse` in its struct declaration, by a documented Mojo mechanism: directly, through a trait that refines it, or as a conditional conformance (`struct W[T](ToErrorResponse where conforms_to(T, Writable))`: `W[Int]` converts, `W[Plain]` is 500; documented in the Mojo 1.1.0 manual, "Parameters" and "Parameterized declarations"). A parametric struct declaring the trait, and a `comptime` alias of a conforming type, are the same declaration. Muntin detects it with the library's generic `conforms_to(E, ToErrorResponse)`. Everything else is the fixed 500, error dropped unread, as since M2-011:
- `Never` (non-raising): the `except` never runs; `conforms_to(Never, ToErrorResponse)` is false and compiles.
- `raises` (`Error`): no opt-in. `Error` carries only text, and an application module cannot give it the trait (`__extension Error(ToErrorResponse)` fails: `'Error' does not implement all requirements for 'ToErrorResponse'`, `error_extension.mojo`). Muntin never maps by message.
- an opted-in type thrown inside a bare-`raises` handler: on 1.1.0 it propagates only if it is `Writable`, and then as `Error` (type erasure), so it is 500; a non-`Writable` one does not compile there (`cannot call function that may raise 'T' in context that supports an error type of 'Error'`). The declared type decides, not what was thrown inside.
- a type conforming only to `ToResponse`: 500 when raised, its `to_response` never runs (it still converts when returned).
- a type with a method named `to_error_response` but no declared conformance: 500 (traits are nominal; the method never runs).
- `raises Variant[A, B]`, even if `A` and `B` opt in: 500 (`Variant` does not conform; a handler with several failure kinds uses one opted-in error type with several kinds instead). `raise Response.text(...)`: 500 (`Response` conforms only to `ToResponse`).

**Observed compiler behavior, not a supported opt-in.** On Mojo 1.1.0 the undocumented `__extension`, written in the error type's own module, is observed to satisfy the generic detection (fresh-context review probe: 404), although a direct non-generic `conforms_to` in that module reports false. Muntin does not reject it, but does not support it as a way to opt in: if Mojo changes this, Muntin's contract is unaffected. Across modules `__extension` cannot add the trait at all (`'T' does not implement all requirements`, the same diagnostic for an application struct as for `Error`, `error_extension.mojo`). Both are compiler evidence and revisit data only.

**No silent change.** `ToErrorResponse` is new, so no type compiled today conforms to it, and `_handler_error`'s `else` branch is exactly today's body: every handler that compiles today answers the same. A scratch copy of `src/muntin` with exactly the slice below applied passes every existing suite (`test_app` 23/23, `test_body` 12/12, `test_error` 11/11 including the raised-`Gone` 500, `test_handler_storage` 6/6, `test_int_body` 13/13, `test_response` 8/8, every spike), every `compile_fail`/`*_fail` fixture with its current diagnostic, and `check_flare.sh` (adapter 8/8, loopback 2/2), unchanged; a new test there converts a `raises NotFound` error on all four argument shapes while `raises Gone` and `raises` stay 500.

**Separate channels.** Returned values convert with `to_response`, raised values with `to_error_response`; neither trait implies the other. A type conforming to both answers each channel with its own method (`Stale`: returned 200, raised 409). The distinct method name is what makes that possible: a requirement spelled `to_response` would give a both-conforming type one conversion for both channels. Returning a type that conforms only to `ToErrorResponse` is rejected as any non-result type is (`does not conform to trait 'ToResponse'`, `error_type_is_not_a_result.mojo`).

**Ownership and fallibility.** `var self`, consumed once, after the handler raised; the result conversion does not run. `deinit self` implementations conform and can move a field out (`ApiError`). The trait refines only `Deinitable`, the bound the handler's `E` already has: the conversion consumes the caught value and needs no `Movable` or `Copyable` (on 1.1.0 every struct is implicitly `Movable`, so the bound costs nothing either way). `self`, `var self` and `deinit self` implementations conform; with `var self` the destructor runs once after the conversion, with `deinit self` it does not run. Non-raising: a raising implementation does not conform (`does not implement all requirements for 'ToErrorResponse'`, `raising_error_conversion.mojo`). A fallible conversion is separable and deferred: if one is needed, the fixed 500 is the natural answer to a failed conversion, decided with logging. Muntin does not check the status a conversion returns, as for `ToResponse`: the application's type decides.

**Why detection, not overloads.** Detection is one compile-time branch in one private function. The eight overloads, the adapters, `App.handle`, `_Erased`, `_Call[F]` and the unsafe surface are untouched, and `E` keeps its `Deinitable` bound, so no error type must conform to anything new. A twin overload bounded `E: ToErrorResponse` beside the inferred `E: Deinitable` one is ambiguous for an opted-in type (`ambiguous call to 'get'`, `bounded_error_twins.mojo`), and anything else would be an overload redesign. Module boundary: `conforms_to` in the library sees a conformance declared only in the application module; `check.sh` builds `tests/error_response_lib_only/driver.mojo` (its move-only `Missing` opts in, `Opaque` does not) without the application module.

**Candidates** (Mojo 1.1.0 (8189361e)):

| Candidate | Result | Verdict |
|---|---|---|
| 1. per-error-type conversion, `ToErrorResponse` + `comptime if conforms_to` in `_handler_error` | opted-in move-only, refinement-conforming and `deinit self` types convert on GET `def(Int)` (path and query) and POST `def(Int, B)` with `String` and `ToResponse` results; every other kind stays 500; 400/404 unchanged; library built without the app module | **chosen** |
| 1b. per-type conversion by twin overloads bounded `E: ToErrorResponse` | `ambiguous call to 'get'` (`bounded_error_twins.mojo`) | eliminated by the compiler |
| 1c. reuse `ToResponse` for raised values | the M2-010 spike's `catch_converting` shows it works mechanically | rejected: changes today's 500 for every raised `ToResponse` type silently, and gives both channels one conversion |
| 2a. application-level mapper as an `App` parameter (`App[on_error=m]`) | the mapped app is a different type: a backend holding `App` rejects it (`cannot be converted from 'MappedApp[not_found[_]]' to 'MappedApp'`, `app_parameter_mapper.mojo`); the mapper must dispatch on `E == NotFound` | rejected: `TestClient` and the Flare adapter's `MuntinHandler` would become generic over the application's error policy (backend coupling, A4) |
| 2b. application-level mapper registered at run time (`app.on_error(m)`) | not built: a library-side field or `Variant` cannot name an application type (M2-003), so mappers for several error types need heterogeneous erased storage and a run-time type identity to select one from an adapter that knows `E` only at compile time | rejected: new storage, type IDs and unsafe code; public `App` state |
| 2c. per-route mapper parameter (`app.get["/users/{id}", on_error=m](get_user)`, default `fixed_500[E]`) | compiles in a scratch probe (not retained) | rejected: source-compatible (a defaulted parameter) and statically typed, but it adds a parameter to all eight overloads, is repeated per route rather than central, and a mapper for `Error` would map by message |
| 3. keep the fixed 500 only | the application can map today without Muntin: a wrapper parameterized by handler and mapper, `app.get["/users/{id}"](mapped[find_user, not_found])`, on the production `App` (`test_application_wrapper_maps_errors_on_the_production_app`) | kept as the fallback for every type that does not opt in; as the only model it costs one wrapper per argument shape and the wrapper at every registration, which candidate 1 removes |

DX section 6 asks for central conversion: with candidate 1 an application that wants one place defines one error type with several kinds (Mojo functions declare one error type) and one `to_error_response` (`ApiError`: 409 and 422), or a trait refining `ToErrorResponse` for a family of types.

**Storage and backends.** Unchanged: `_Erased`, `_Call[F]`, `App.handle(Request) -> Response`, the unsafe surface, `TestClient`, the Flare adapter. The conversion runs inside the adapter, which alone knows `E`; backends still receive only a `Response`, and application error types never cross the seam.

**Evidence.** `tests/error_response_spike.mojo` (library side: the candidate trait, `_handler_error`, production's `_call_int`/`_call_int_body` and two shapes' overloads over production `_Erased`) and `tests/test_spike_error_response.mojo` (8 tests): successful `String`/`ToResponse` results unchanged; opted-in `NotFound` (move-only), `Locked` (no trait but the error trait), `ApiError` (refinement, `deinit self`) converted once with the result conversion not run; `Rejected`, raised `Gone` (`ToResponse` only) and `Lookalike` 500 with nothing converted; `Stale` per channel; bare `raises` and an erased opted-in type 500; 400/404 with nothing run; app moves; the application wrapper on the production `App`. `tests/error_response_lib_only/driver.mojo` (built by `check.sh` without the application module). `tests/error_response_fail/*.mojo` (5): `bounded_error_twins`, `error_type_is_not_a_result`, `raising_error_conversion`, `error_extension`, `app_parameter_mapper`. Mutations, planted in the spike and reverted, each red: detecting `ToResponse` instead (4 tests), never converting (3 tests), converting `ToResponse` types too (1 test), the library naming an application error type (lib-only build: `unable to locate module`). Not retained: the scratch slice above; the per-route probe (2c); the non-`Writable` erasure probe. Fresh-context review: no material issue; it reproduced the scratch slice and the mutations, and probed refinements, parametric and conditional conformance, aliases, a same-named application trait under `from muntin import *` (the local trait wins: 500), `self`/`var self`/`deinit self` with destructor counts, `Variant` errors and the twins with production's signatures. Its minor findings are applied: the opt-in rule covers conditional conformance and the same-module `__extension` behavior is recorded (as observed compiler behavior outside the supported contract), `error_extension.mojo` is a general cross-module limit, the slice names `_Call`'s docstring and `app.mojo`'s module comment, 2c's cost is stated precisely, and `Variant`/`raise Response` cases are listed.

**Revisit when:**
- `bounded_error_twins.mojo` compiles (constraint-based ranking): detection in one function is still preferred;
- `error_extension.mojo` compiles (`__extension` adds a trait across modules, for `Error` or any type): decide whether `Error` may conform (one response for every bare-`raises` error, by message only) and whether applications may opt in types they do not own; likewise if `Error` gains structured payloads or `except` gains type matching;
- `__extension` becomes documented: decide whether it joins the supported opt-in rule; a direct and a generic `conforms_to` that start to agree (or the generic one that stops seeing a same-module extension) change only the observed-behavior note;
- `error_type_is_not_a_result.mojo` or `raising_error_conversion.mojo` compiles, or the lib-only driver stops answering 404 (`conforms_to` no longer sees a cross-module conformance);
- `app_parameter_mapper.mojo` compiles (parameterized types convert to their default), which would remove 2a's coupling cost;
- a fallible error conversion or a logging hook (M3) is needed: decide what a failed conversion answers and where dropped and converted errors are reported;
- applications need to map error types they do not own and cannot wrap: the wrapper (3) is the fallback until then.

**Next production slice.** Application-defined error responses, exactly as above:
- `src/muntin/http.mojo`: public `trait ToErrorResponse(Deinitable)` with non-raising `def to_error_response(var self) -> Response`, exported from `muntin`. Re-check the name (`ToErrorResponse`/`to_error_response`) once before it becomes public.
- `src/muntin/app.mojo`: `_handler_error[E]` gains the `comptime if conforms_to(E, ToErrorResponse)` branch; its `else` branch is today's body. The module comment at the top of `app.mojo`, `_handler_error`'s docstring and the overload docstrings that say a raised value is always 500 change with it. No overload, adapter, `App.handle` or storage code change.
- `_handler_storage.mojo`: only `_Call`'s docstring ("turns a handler error into 500" becomes "into a response").
- Unchanged: `body.mojo`, `testing.mojo`, `adapters/flare/muntin_flare.mojo`, the unsafe surface, `ToResponse`, every existing suite and fixture (scratch-verified twice, including by the fresh-context review: none changes).
- Tests: opted-in `raises T` (move-only, refinement, `deinit self`) on all four argument shapes with `String` and `ToResponse` results, converted once and the result conversion not run; `raises`, non-opted `raises T`, raised `ToResponse`-only and same-named-method types stay the fixed 500; a both-conforming type per channel; 400/404 unchanged with nothing run; `TestClient` and loopback through Flare agree for one opted-in route. Production fixtures for a returned error-only type and a raising `to_error_response`.
- Docs: DX section 6 and "Proven vs. target status".
- Not in the slice: mapping `Error` or messages, application-level or per-route mappers, logging, fallible conversion, headers, JSON, raw `Request` handlers, middleware, state, new shapes.
