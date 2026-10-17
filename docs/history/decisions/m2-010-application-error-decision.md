# Application-error decision (M2-010)

> **Current.** Now described in [errors reference](../../reference/errors.md#errors) and [ARCHITECTURE, "Mojo 1.1.0 facts the design rests on"](../../ARCHITECTURE.md#mojo-110-facts-the-design-rests-on).
> Changed in part since:
> - [M2-012](m2-012-error-response-decision.md): the deferred application-defined conversion was decided: an opt-in ToErrorResponse beside the fixed 500.
> - [M3-014](m3-014-registration-structure-decision.md): the eight overloads became generic-arity slots; E is still inferred per overload.
> - [M3-058](m3-058-dropped-error-report-decision.md): the dropped error is no longer lost: the fixed 500 carries a report middleware can read.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M2-010, merged as PR #18); production implements it since M2-011 ("Raising handlers in production (M2-011)", below). This section decides how a handler such as `def get_user(id: Int) raises -> User` registers with the existing `app.get["/users/{id}"](get_user)` syntax, where request failures stop and handler failures begin, and what a handler failure becomes on the wire, while `App.handle(Request) -> Response` stays the backend seam.

```text
route match            no match                            -> 404   (App.handle)
query gathering        _query_value raises                 -> 400   (App.handle, its own try)
route value            _parse_int raises                   -> 400   (adapter, its own try)
body                   B.from_body raises                  -> 400   (adapter, its own try)
handler call           handler raises E                    -> 500   (adapter, the only step in its try: _handler_error[E])
result                 respond(result^)  non-raising       -> the handler's response
invoke raises          (no adapter does)                   -> 500   (App.handle; never 400)
```

**Contract.** A handler may be non-raising (as today), declare `raises` (error type `Error`), or declare `raises T` for an application-defined `T`, on every existing argument shape and with either return policy. Registration syntax and the eight overloads stay as they are; each overload's function type gains one inferred error type, `E: Deinitable`:

```mojo
def get[E: Deinitable, //, path: StaticString](mut self, handler: def(Int) thin raises E -> String)
def get[E: Deinitable, R: ToResponse, //, path: StaticString](mut self, handler: def(Int) thin raises E -> R)
# likewise def(), def(var B) and def(Int, var B) on post
```

**Function type: parametric raises.** Mojo 1.1.0 documents this mechanism ("Parametric raises" in the errors chapter of the manual): a function-type parameter declared `thin raises E` infers `E` from the argument, and a non-raising argument infers `Never`, which the manual defines as equivalent to omitting `raises`. Measured: in one overload set, `E` is `Never` for a non-raising handler, `Error` for `raises`, and the application's type for `raises NotFound`. `-> StaticString` still converts to the `String` overloads, a borrowed `body: B` still converts to `var B`, and `B`, `E` and `R` are inferred together on the body shapes (`test_spike_error`, all eight overloads). Because `E` is inferred in every overload, it never decides between overloads. Shape still decides through arity and parameter types, and the `R: ToResponse` bound still decides the return policy, as since M2-008. No overload ranking is involved.
- `E: Deinitable`, not `AnyType`: the adapter catches the error and drops it, and a caught value bounded only by `AnyType` fails with `'e' abandoned without being explicitly destroyed` (`tests/error_fail/catch_unbounded_error_type.mojo`). `Never` and `Error` satisfy the bound. A linear error type (`Deinitable where False`) is rejected at registration (`does not conform to trait 'Deinitable'`), as is a handler declared `-> Never` (no result type to convert); both are unsupported, not ambiguous (fresh-context review probes, not retained).
- Spelling: `thin raises E`, the manual's order. `raises E thin` compiles, but `mojo format` on 1.1.0 cannot parse it (`Cannot parse`). Compiler notes print the type as `raises Never thin` (`tests/error_fail/wrong_arity_note.mojo`).

**Candidates for raising handlers** (all on Mojo 1.1.0 (8189361e)):

| Candidate | Result | Verdict |
|---|---|---|
| 1. widen each function type to a bare `raises` | non-raising and `raises` handlers convert (`test_widened_candidate_takes_error_and_non_raising_handlers`); a `raises NotFound` handler does not: `error type of the first type is 'NotFound' but the second type is 'Error'` (`typed_error_to_widened_type.mojo`) | rejected: blocks typed errors, the only channel that carries an application type to the catch (below); accepting them later would need a second signature change. With `E` fixed to `Error`, extraction and the handler call could also share one `try` unnoticed. |
| 2. a raising twin beside each non-raising overload | a non-raising handler converts to both: `ambiguous call to 'get'` (`raising_twin_overloads.mojo`); a raising handler selects the twin | eliminated by the compiler: no ranking prefers the exact match |
| 3. keep the shapes and infer the error type (parametric raises) | non-raising, `raises` and `raises T` on all eight overloads, mixed in one `_Erased` list, after `App` moves | **chosen** |

**Request failures versus handler failures.** One rule: a request-side failure is answered 400 by the step that fails, before the handler runs, and only the handler call sits in the adapter's handler `try`, whose error becomes 500. Query gathering keeps its place in `App.handle`, in its own `try`. `_call_int` and `_call_int_body` answer a `_parse_int` failure with 400 themselves, as `_call_body` already does for `from_body`, instead of raising into `App.handle`'s broad `except`. `respond` runs after the `try`, so the catch covers exactly the handler. Three compiler facts support the split:
- a `try` block has one error type, so an adapter cannot put `_parse_int` (raises `Error`) and the handler call (raises `E`) in one `try`: `cannot call function that may raise 'E' in context that supports an error type of 'Error'` (`extraction_and_handler_in_one_try.mojo`; the generic body is checked, so this holds for every `E`);
- a typed error cannot reach `App.handle`: `_Call[F]` raises `Error`, and an adapter that lets `E` escape does not convert to it (`typed_error_escaping_the_adapter.mojo`), so the adapter, the only code that knows `E`, chooses the response;
- 500 depends on which step raised, not on the error: a handler raising `Error("not an integer")`, `_parse_int`'s own text, is 500, while a bad value on the same route is 400 (`test_500_depends_on_the_step_not_the_message`).

`App.handle` keeps one `except` around `invoke`, mapped to 500: no adapter raises any more, so a raise there means a broken adapter, a server fault, never a client error. `_Call[F]` stays `raises` (a non-raising adapter converts to it), so `_handler_storage.mojo` does not change.

**Wire.** An unhandled handler error is `500` with the fixed text body `Internal Server Error`, like the fixed `Bad Request` and `Not Found` bodies. The error value is dropped unread. An `Error`'s message is arbitrary handler text: the spike's handlers raise `database password is hunter2` and `insert failed: duplicate key users_pkey`, both readable at the catch (`caught_text`) and absent from the response (`test_handler_error_text_never_reaches_the_client`). Muntin has no logging or observability hook, and printing to stderr from the library would be a policy decided with observability (M3), so the error is currently lost. An application that needs a specific response catches inside its handler and returns a `Response`.

**What Mojo exposes at the catch.** The adapter's `except e:` binds a value of the handler's error type, inferred:
- `raises` gives `Error`: a message (`Writable`, `String(e)`) and an optional stack trace (`get_stack_trace()`, collected only with `MODULAR_DEBUG=stack-trace-on-error`). It carries no application type: a typed error that passes through a bare-`raises` function arrives as `Error` (the manual's "type erasure"; on 1.1.0 only a `Writable` error type erases, otherwise the call does not compile: `cannot call function that may raise 'T' in context that supports an error type of 'Error'`, measured in M2-012), and `Error` is a stdlib type an application cannot conform to a Muntin trait (`__extension` is undocumented).
- `raises T` gives `e: T`, statically typed, with its fields. The documented `comptime if conforms_to(E, ToResponse)` refinement lets code at the catch call `e^.to_response()`: the evidence helper `catch_converting` answers a `raises Gone` handler (`Gone: ToResponse`) with 410 (`test_typed_error_reaches_the_catch_boundary_with_its_type`). `ErrorApp` does not do this.
- A function declares at most one error type. Several failure kinds in one handler need one enumerated struct or a `Variant`, and an `Error`-raising call inside a `raises T` function must be caught and wrapped (manual: errors chapter).

**Application-defined error conversion: deferred.** The fixed 500 is the first error model. Conversion works mechanically for typed errors (above) but is not adopted:
- it would cover only `raises T` handlers. Mojo's recommended default, a bare `raises`, gives `Error`, which carries only text, so conversion would split handlers into two error models, or map errors by message;
- DX section 6 asks for central conversion. Whether that is per error type (the type conforms, as results do with `ToResponse`) or an application-level mapping, and how a handler with several failure kinds reads under one-error-type-per-function, is a DX decision with its own evidence;
- the fixed 500 is needed in any design, for `Error` and for error types that do not convert.

**A raised value is a handler error, whatever its type.** The rule is decided by control flow: a value the handler returns goes through the response policy, and a value it raises is a fixed 500. The error type's traits do not matter: a type that conforms to `ToResponse` converts when returned (`Gone` → 410) and is 500 when raised, with its `to_response` never run (`test_raised_to_response_value_is_a_handler_error`). The slice does not reject such error types. That would narrow what applications may raise for the sake of a conversion design that is not chosen yet. The later conversion stays additive without it, provided it is an explicit opt-in (its own trait, or an application-level mapping the application registers) rather than implied by `ToResponse`: a handler that raises a `ToResponse` type keeps its 500 until the application opts in.

**`ToResponse` stays non-raising.** Raising handlers do not require fallible conversion: the handler's error is caught before `respond` runs, and the conversion only sees a returned value. A fallible `to_response` remains the separate M2-007 revisit condition.

**Storage and backends.** `E` exists only in the adapter instantiation (`_call_int[E, R, respond]`) and in the stored function type `F`. `_Erased`, `_Call[F]` and the unsafe surface are unchanged, and the spike stores every kind in production's `_Erased`. `TestClient` and the Flare adapter still receive only the final `Response`; status 500 is chosen in Muntin, not in an adapter. `adapters/flare/muntin_flare.mojo` needs no change: on a scratch copy of `src/muntin` with the slice below applied, `check_flare.sh` passes unchanged (adapter 8/8, loopback 2/2).

**Evidence.** `tests/error_spike.mojo` is the library side: production `_Erased`, `FromBody`, `ToResponse`, `_text`/`_converted`, `_match`, `_parse_int` and `_query_value`, plus `ErrorApp` with the eight widened overloads, the adapters, the split `handle`, candidate 1 (`get_widened`) and the catch-boundary helpers. `tests/test_spike_error.mojo` is the application side (10 tests): non-raising handlers unchanged (including `-> StaticString`, `-> Response` 418 and `(Int, B)`); raising `Error` and `NotFound` handlers succeeding and failing on every shape, with `String` and `ToResponse` results; a fixed 500 with the result conversion never run; message independence; no leak; every request failure 400 with the handler count at 0; 404; app moves; candidate 1; a `ToResponse` type converted when returned and 500 when raised; the typed catch. `check.sh` builds `tests/error_lib_only/driver.mojo` without the application module, so its error type `Missing` is unknown to the library. `tests/error_fail/*.mojo` (6) are checked for their diagnostics. Mutations, planted and reverted, each red: handler error answered 400 (5 tests), 500 answered as 200 (6 tests), query gathering answered 500 (1 test), `_parse_int` moved into the handler's `try` (compile error, above), `_handler_error` converting a raised `ToResponse` value (1 test). Not retained: a scratch copy of `src/muntin` with exactly the slice below applied precompiles with `--Werror`; it passes `test_app` 23/23, `test_body` 12/12, `test_int_body` 13/13, `test_response` 8/8, every spike and `check_flare.sh` unchanged. It fails only the fixtures and the one storage test listed under the slice. Sources: Mojo 1.1.0 (8189361e) for every compile claim; modular/modular at tag `mojo/v1.1.0`: `docs/site/manual/errors.mdx` (typed errors, `Never`, parametric raises, type erasure through bare `raises`, one error type per `try`, `get_stack_trace`) and `docs/site/releases/v0.26.1.md`/`v0.26.2.md` (typed errors introduced).

**Revisit when:**

- inference of the error type changes: `test_non_raising_handlers_are_unchanged` or `wrong_arity_note.mojo` changes result, or `raising_twin_overloads.mojo` starts compiling (twins would then rest on ranking; one overload per shape is still preferred);
- `typed_error_to_widened_type.mojo` compiles (typed errors convert to `Error`), or `typed_error_escaping_the_adapter.mojo` compiles (a typed error could reach `App.handle`);
- `extraction_and_handler_in_one_try.mojo` compiles: the compiler no longer keeps the two catches apart, and only tests do;
- application-defined error responses are needed: decide per-type conversion versus an application-level mapping, as an explicit opt-in so that today's 500 for a raised `ToResponse` type does not change silently (decided in M2-012, below);
- an observability or logging hook arrives: decide where a dropped handler error goes;
- `Error` gains structured payloads, or `except` gains type matching;
- `mojo format` accepts `raises E thin` (spelling only);
- `tests/storage_fail/typed_thin_value_handler.mojo` compiles: a value typed `def() thin -> String` converts to `def() thin raises E -> String` again, and the M2-011 source-compatibility exception can be dropped.

**Next production slice.** Raising handlers with a fixed 500, nothing more:

- `src/muntin/app.mojo`: each of the eight overloads gains `E: Deinitable` (inferred, before `//`) and its function type becomes `thin raises E`; route and body `comptime assert`s and messages are unchanged. `_call_none`, `_call_int`, `_call_body` and `_call_int_body` gain `E` as their first non-body parameter. `_call_int` and `_call_int_body` answer a `_parse_int` failure with 400 themselves. Each adapter calls the handler alone in a `try` whose `except` returns `_handler_error[E]` (fixed 500, whatever `E` is), then `respond(result^)`. `App.handle` gathers the query value in its own `try` → 400 and maps a raise from `invoke` to 500. Docstrings that say handlers do not raise change with it.
- Unchanged: `_handler_storage.mojo` code (one docstring sentence changes: `_Call`'s "Raising means an argument failed to convert" becomes false, since no adapter raises; a raise out of `invoke` is a server fault), `http.mojo` (`ToResponse` non-raising), `body.mojo`, `testing.mojo`, `adapters/flare/muntin_flare.mojo`, the unsafe surface, and every `compile_fail` fixture.
- Fixtures, verified on the scratch copy:
  - start compiling and retire into positive tests: `storage_fail/raising_handler.mojo`, `storage_fail/raising_typed_handler.mojo`, `body_fail/post_raising_handler.mojo`, `body_fail/post_int_body_raising_handler.mojo`, `body_fail/post_int_body_raising_typed_handler.mojo`;
  - notes gain `raises Never` (for example `'def(Int) raises Never thin -> String'`): `storage_fail/{request_param_handler,string_param_handler,two_param_handler,mismatched_trampoline}.mojo` and `body_fail/{get_body_handler,post_body_then_int,post_int_and_two_bodies,post_int_body_non_conforming_return,post_no_param,post_owned_int_and_body,post_two_bodies}.mojo`;
  - `storage_fail/{copy_erased,downstream_move_header,mismatched_trampoline}.mojo` spell the adapters `[Never, String, _text]`;
  - `test_handler_storage.test_app_routes_hold_erased_handlers` expects a returned 400 for `4_2` instead of a raise.
- Tests: `raises` and `raises T` handlers on every shape with `String` and `ToResponse` results → 500 `Internal Server Error`, conversion not run, no error text in the body; every existing 400 and 404 case with the handler not called; 500 independent of the message; a raised error type that conforms to `ToResponse` is 500 and its `to_response` does not run; `TestClient` and loopback through Flare agree for one raising route (500) next to the existing routes.
- Docs: DX section 6 and "Proven vs. target status" list raising handlers and the 500; the DX status lines that call every handler shape non-raising, list `raises` among the shapes `get` rejects, and quote the note `'def(Int) thin -> String'` (now `raises Never thin`) change with it.
- Not in the slice: application-defined error conversion, logging, fallible `ToResponse`, raw `Request` handlers, JSON, headers, new methods, middleware, state.
