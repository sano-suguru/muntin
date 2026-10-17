# Errors

Every handler shape may be non-raising, `raises` or `raises T` for an application type `T`; registration does not change. Mojo infers the error type.

```mojo
def get_user(id: Int) raises -> User:        # or raises T, an application error type that does not opt in
    if id == 0:
        raise Error("no such user")
    return User(id, "Ada")


app.get["/users/{id}"](get_user)              # unchanged registration
# GET /users/1   -> 200, User converted as today
# GET /users/0   -> 500 "Internal Server Error"   (the error text is not sent)
# GET /users/abc -> 400 "Bad Request"             (get_user not called)
```

- Request failures are decided before the handler: an invalid route value, a missing, duplicated or invalid query value, or a body a conversion rejects is 400; a path no route matches is 404; a path only other methods match is 405.
- **Anything the handler raises is a fixed 500 `Internal Server Error`, whatever the error says**, unless its declared type opts in (below). The error's text is never sent; it is kept on the response for middleware (below).
- Returning and raising differ: a returned value is converted with `to_response`; a raised one is a handler error, even if its type conforms to `ToResponse`.
- An error type must be `Deinitable`: a linear error type is rejected at registration.

## Application error responses (`ToErrorResponse`)

An error type opts in by declaring `ToErrorResponse`:

```mojo
from muntin import App, Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):     # the opt-in, in the type's own declaration
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def get_user(id: Int) raises NotFound -> User:
    ...


app.get["/users/{id}"](get_user)
# GET /users/0   -> 404 "no user 0"          (NotFound.to_error_response; User not converted)
# GET /users/abc -> 400 "Bad Request"        (get_user not called)
```

- Only the handler's declared error type decides: `raises T` converts when `T` declares `ToErrorResponse` in its own declaration (directly, through a refining trait, or as a conditional conformance such as `struct Missing[T: AnyType](ToErrorResponse where conforms_to(T, Writable))`). Bare `raises` (`Error`) stays the fixed 500, and an opted-in type raised inside a bare-`raises` handler arrives as `Error`. Muntin never maps by message. A type that only conforms to `ToResponse` (`raise Response.text(...)`), merely has a `to_error_response` method, or is a `Variant` of opted-in types stays 500. `__extension` is not a supported way to opt in.
- A type may conform to both traits: returned, `to_response`; raised, `to_error_response`. A type conforming only to `ToErrorResponse` cannot be returned.
- One central mapping is one error type with several kinds (a function declares one error type), or an application trait refining `ToErrorResponse`.
- The conversion runs once, consumes the error and cannot raise (a raising `to_error_response` does not conform).

## Reports of dropped errors

When Muntin answers the fixed 500, the `Response` carries a report of what it dropped, which [middleware](middleware.md#logging-dropped-errors) reads; the client receives exactly the same 500 ([M3-058](../history/architecture-decisions.md#dropped-error-report-decision-m3-058), [M3-059](../history/architecture-decisions.md#dropped-error-report-amendment-m3-059)).

```mojo
from muntin import Failure


def find_order(id: Int) raises -> String:
    if id == 0:
        raise Error("database password is hunter2")
    return "order " + String(id)

# GET /orders/0 -> 500 "Internal Server Error", no fields; in middleware:
#   response.failure().value().source  == Failure.HANDLER       ("handler")
#   response.failure().value().message == "database password is hunter2"
#   String(response.failure().value()) == "handler: database password is hunter2"
# GET /orders/1 -> 200 "order 1"; response.failure() is None
```

- `Response.failure() -> Optional[Failure]` returns a copy. `Failure.source` is the step that dropped the error:
  - `Failure.HANDLER` (`"handler"`): a handler raised and its declared type does not opt in;
  - `Failure.MIDDLEWARE` (`"middleware"`): a middleware raised;
  - `Failure.RESPONSE` (`"response"`): a `Json[T]` result's `write_json` failed;
  - `Failure.MUNTIN` (`"muntin"`): an internal failure; the only reachable one is the rebuild of a header field an in-memory `Headers` holds invalidly, with the fixed message `the request's header fields could not be rebuilt`.
- `Failure.message` is the error's text when its type is `Writable`, else `<module.Type>`. A `Failure` writes itself as `source: message`. There is no stack trace.
- Only Muntin's fixed 500 carries a report. The application's own responses (its own 500 included), converted errors, 400, 404, 405, 413 and 415 have `None`. **A 400 is not always the client's fault**: a request-side conversion that fails for a server-side reason (a missing configuration in `from_body`) is a 400 with no report.
- The report stays with the response through copies, `HEAD` and edits; a response built anew has none.
- No backend sends it: the error's text reaches the client only if the application writes it. Muntin has no logger.
- **`message` is not safe log text**: it may hold secrets, control characters and client input. So may the request's method, path and fields. Escaping and masking are the application's.
- A middleware reads the report on the response it receives. Not read by any middleware: a raise out of the outermost middleware (only the caller of `App.handle` sees it), a report an inner middleware drops by answering a new response, and a report replaced by a later failure. Not reported at all: the Flare adapter's own 500 for an invalid outgoing field, and the 400s.
- An application does not build a `Failure` (its initializer takes only `_`-prefixed keywords).
