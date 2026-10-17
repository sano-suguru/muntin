# Application-defined error responses in production (M2-013)

> **Current.** Now described in [errors reference, "Application error responses (`ToErrorResponse`)"](../../reference/errors.md#application-error-responses-toerrorresponse) and [ARCHITECTURE, "Request handling"](../../ARCHITECTURE.md#request-handling).
> Changed in part since:
> - [M3-058](m3-058-dropped-error-report-decision.md): the fixed-500 kinds now carry a report of the dropped error.

Production implements the M2-012 slice above ("Next production slice"), and nothing more. The public contract, in `http.mojo` and exported from `muntin`:

```mojo
trait ToErrorResponse(Deinitable):
    def to_error_response(var self) -> Response: ...
```

and the one private function every adapter calls on a handler error:

```mojo
def _handler_error[E: Deinitable](var e: E) -> Response:
    comptime if conforms_to(E, ToErrorResponse):
        return e^.to_error_response()
    else:
        return _internal_error()        # the fixed 500, as in M2-011
```

- **Name:** re-checked before it became public: `ToErrorResponse`/`to_error_response` collides with nothing in Muntin or the Mojo 1.1.0 prelude (an unimported `ToErrorResponse` is `use of unknown declaration`), and keeps the method distinct from `to_response`, which the per-channel rule needs. Kept.
- **Opt-in rule:** exactly M2-012's. The handler's declared error type `T` (`raises T`) declares the conformance on its own struct: directly, through a trait refining it, or as a documented conditional conformance. Undocumented `__extension` behavior is compiler evidence only (M2-012), not supported API.
- **Fixed 500** (`Internal Server Error`, error dropped unread): bare `raises` (`Error`, never mapped by message), a `raises T` whose `T` does not opt in, a conditional conformance whose condition fails, an opted-in `Writable` type erased to `Error` by a bare-`raises` handler, a raised type conforming only to `ToResponse` (including `Response` itself), a type with a same-named method but no conformance, and a `Variant` of opted-in types.
- **Channels:** a returned value converts with `to_response`, a raised one with `to_error_response`; neither trait implies the other. A type conforming to both answers each channel with its own method. A type conforming only to `ToErrorResponse` cannot be returned (`storage_fail/error_type_is_not_a_result.mojo`).
- **Ownership and fallibility:** the caught error is moved into `to_error_response` once; the result conversion does not run. Destructor counts: `var self` and borrowed `self` implementations drop the error exactly once after converting it, `deinit self` consumes it without running the destructor, a non-opted error is dropped once by the 500 branch. Non-raising: a raising implementation does not conform (`storage_fail/raising_error_conversion.mojo`).
- **Unchanged:** the eight overloads' signatures and checks, the adapters' code, `App.handle`'s code, `_Erased`, `_Call[F]`, the unsafe surface, `body.mojo`, `testing.mojo`, `adapters/flare/muntin_flare.mojo`. `app.mojo` changes `_handler_error`'s body, its import and comments/docstrings (module comment, `_handler_error`, the eight overloads, `App.handle`); `_handler_storage.mojo` only `_Call`'s docstring ("turns a handler error into a response"); `http.mojo` adds the trait and rewords one sentence of `ToResponse`'s docstring (it said the application-error model did not exist yet); `__init__.mojo` exports it. `check_unsafe.sh` gains one guard (below). No existing test case or fixture changed (the loopback test only gains cases): `tests/test_error.mojo` is intentionally byte-identical, since none of its error types opts in, and it is the evidence that every M2-011 500 is unchanged.
- **Evidence:** `tests/test_error_response.mojo` (9): opted-in move-only `raises NotFound` on `def()`, `def(Int)` from a path and a query value, `def(B)` and `def(Int, B)` (path and query), each with a `String` and a `ToResponse` result, answering normally when it returns (error conversion 0, result conversion as before) and 404 with its own body when it raises (error conversion once, destructor once, result conversion 0); `Copyable` `Conflict` with a borrowed `self`; `ApiError` through a refining trait with `deinit self` (409/422, destructor 0); conditional `Missing[Int]` converts and `Missing[Plain]` is 500; the fixed-500 kinds above (including `raises Response` and `raises Variant[Conflict, Stale]`), none converted, no error text; `Stale` per channel; 400 and 404 on opted-in routes, raising or not, with the handler and both conversions not run; `TestClient` equal to `App.handle`. Loopback through Flare: `GET /stock/{id}` (`raises OutOfStock -> String`, `OutOfStock` declared in the test module) answers 409, 200 and 400 equal to `TestClient`. The M2-012 spike and `tests/error_response_fail` stay as decision evidence (rejected twins, mapper coupling, `__extension` limit).
- **Not in the slice:** mapping `Error` or messages, application-level or per-route mappers, logging, fallible conversion, raw `Request` handlers, JSON, headers, middleware, state, new methods or shapes.
