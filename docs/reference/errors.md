# Errors

Every handler shape may be non-raising, `raises` or `raises T` for an application type `T`; registration does not change. Mojo infers the error type. Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

<!-- example: tests/test_reference_examples.mojo#errors-fixed-500 get_user_or_500=get_user -->
```mojo
def get_user(id: Int) raises -> UserText:    # or raises T, an application error type that does not opt in
    if id == 0:
        raise Error("no such user")
    return UserText(id, "Ada")


var app = App()
app.get["/users/{id}"](get_user)              # unchanged registration
# GET /users/1   -> 200 "1 Ada", converted by `to_response`
# GET /users/0   -> 500 "Internal Server Error"   (the error text is not sent)
# GET /users/abc -> 400 "Bad Request"             (get_user not called)
```

`UserText` is the `ToResponse` type of [responses](responses.md#toresponse). Run by `tests/test_reference_examples.mojo` (`test_errors_fixed_500`), with `get_user` named `get_user_or_500`. `tests/test_error.mojo` (`test_raising_handlers_that_raise_answer_a_fixed_500`, `test_request_failures_are_400_before_a_raising_handler`) checks the same on every handler shape.

- Request failures are decided before the handler: an invalid route value, a missing, duplicated or invalid query value, or a body a conversion rejects is 400, with a report of why ([below](#reports-of-rejected-requests)); a path no route matches is 404; a path only other methods match is 405.
- **Anything the handler raises is a fixed 500 `Internal Server Error`, whatever the error says**, unless its declared type opts in (below). The error value is dropped; its text (or, for a type that is not `Writable`, its type name, `<module.Type>`) is kept on the response for middleware (below), never sent.
- Returning and raising differ: a returned value is converted with `to_response`; a raised one is a handler error, even if its type conforms to `ToResponse`.
- An error type must be `Deinitable`: a linear error type is rejected at registration.

## Application error responses (`ToErrorResponse`)

An error type opts in by declaring `ToErrorResponse`:

<!-- example: tests/test_reference_examples.mojo#errors-to-error-response get_user_or_404=get_user -->
```mojo
from muntin import App, Response, ToErrorResponse


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):     # the opt-in, in the type's own declaration
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


def get_user(id: Int) raises NotFound -> UserText:
    if id == 0:
        raise NotFound(id)
    return UserText(id, "Ada")


var app = App()
app.get["/users/{id}"](get_user)
# GET /users/1   -> 200 "1 Ada"              (UserText.to_response)
# GET /users/0   -> 404 "no user 0"          (NotFound.to_error_response; nothing returned to convert)
# GET /users/abc -> 400 "Bad Request"        (get_user not called)
```

`UserText` is the `ToResponse` type of [responses](responses.md#toresponse). Run by `tests/test_reference_examples.mojo` (`test_errors_to_error_response`), with `get_user` named `get_user_or_404`. `tests/test_error_response.mojo` (`test_opted_in_errors_convert_once_on_every_shape`) runs a move-only `NotFound` that counts its conversions and drops, on every argument shape.

- Only the handler's declared error type decides: `raises T` converts when `T` declares `ToErrorResponse` in its own declaration (directly, through a refining trait, or as a conditional conformance such as `struct Missing[T: AnyType](ToErrorResponse where conforms_to(T, Writable))`). Bare `raises` (`Error`) stays the fixed 500, and an opted-in type raised inside a bare-`raises` handler arrives as `Error`. Muntin never maps by message. A type that only conforms to `ToResponse` (`raise Response.text(...)`), merely has a `to_error_response` method, or is a `Variant` of opted-in types stays 500. `__extension` is not a supported way to opt in.
- A type may conform to both traits: returned, `to_response`; raised, `to_error_response`. A type conforming only to `ToErrorResponse` cannot be returned.
- One central mapping is one error type with several kinds (a function declares one error type), or an application trait refining `ToErrorResponse`.
- The conversion runs once, consumes the error and cannot raise (a raising `to_error_response` does not conform).

## Reports of dropped errors

When Muntin answers the fixed 500, the `Response` carries a report of what it dropped, which [middleware](middleware.md#logging-dropped-errors) reads; the client receives exactly the same 500 ([M3-058](../history/decisions/m3-058-dropped-error-report-decision.md), [M3-059](../history/decisions/m3-059-dropped-error-report-amendment.md)).

<!-- example: tests/test_failure.mojo#errors-report -->
```mojo
from muntin import App, Failure


def find_order(id: Int) raises -> String:
    if id == 0:
        raise Error("database password is hunter2")
    return "order " + String(id)


var app = App()
app.get["/orders/{id}"](find_order)
# GET /orders/0 -> 500 "Internal Server Error", no fields; on that response
# (as App.handle returns it, or a middleware outside the route receives it):
#   response.failure().value().source  == Failure.HANDLER       ("handler")
#   response.failure().value().message == "database password is hunter2"
#   String(response.failure().value()) == "handler: database password is hunter2"
# GET /orders/1 -> 200 "order 1"; response.failure() is None
```

Run by `tests/test_failure.mojo` (`test_errors_report_example`), as written; it reads the report on `TestClient`'s response and on `App.handle`'s. `test_handler_error_text` registers this `find_order` through `_routes` with fourteen other routes, and `test_outermost_logging_middleware` checks that for `GET /orders/1` no report reaches the logging middleware; a middleware reading this report is in [middleware](middleware.md#logging-dropped-errors).

- `Response.failure() -> Optional[Failure]` returns a copy. `Failure.source` is the step that dropped the error:
  - `Failure.HANDLER` (`"handler"`): a handler raised and its declared type does not opt in;
  - `Failure.MIDDLEWARE` (`"middleware"`): a middleware raised;
  - `Failure.RESPONSE` (`"response"`): a `Json[T]` result's `write_json` failed ([responses](responses.md#json-results)), also when a handler called `to_response()` itself;
  - `Failure.MUNTIN` (`"muntin"`): an internal failure; the only reachable one is the rebuild of a header field an in-memory `Headers` holds invalidly, with the fixed message `the request's header fields could not be rebuilt`.
- `Failure.message` is the error's text when its type is `Writable`, else `<module.Type>`. A `Failure` writes itself as `source: message`. There is no stack trace.
- Only Muntin's fixed 500 carries a `Failure`. The application's own responses (its own 500 included), converted errors, 400, 404, 405, 413 and 415 have `None`; Muntin's 400 has a `Rejection` instead ([below](#reports-of-rejected-requests)).
- The report stays with the response through copies, `HEAD` and edits; a response built anew has none.
- No backend sends it: the error's text reaches the client only if the application writes it. Muntin has no logger.
- **`message` is not safe log text**: it may hold secrets, control characters and client input. So may the request's method, path and fields. Escaping and masking are the application's.
- A middleware reads the report on the response it receives. Not read by any middleware: a raise out of the outermost middleware (only the caller of `App.handle` sees it), a report an inner middleware drops by answering a new response, and a report replaced by a later failure. Not reported at all: the Flare adapter's own 500 for an invalid outgoing field.
- An application does not build a `Failure` (its initializer takes only `_`-prefixed keywords).

## Reports of rejected requests

When Muntin answers 400 before the handler, the `Response` carries a `Rejection`: which step refused the request, the route value's name and why. The client receives exactly the same 400 `Bad Request`, with no fields ([M3-084](../history/decisions/m3-084-request-rejection-report-decision.md)).

<!-- example: tests/test_rejection.mojo#errors-rejection -->
```mojo
from muntin import App, FromJson, Json, JsonValue, Rejection


@fieldwise_init
struct Note(FromJson, Movable):
    var text: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["txet"].string())  # misspelled: every body is 400


def add_note(body: Json[Note]) -> String:
    return body.value.text


def show_user(id: Int) -> String:
    return "user " + String(id)


var app = App()
app.get["/users/{id}"](show_user)
app.post["/notes"](add_note)
# GET /users/abc -> 400 "Bad Request", no fields; on that response
# (as App.handle returns it, or a middleware outside the route receives it):
#   response.rejection().value().step    == Rejection.PATH  ("path")
#   response.rejection().value().name    == "id"
#   response.rejection().value().message == "not an integer"
#   String(response.rejection().value()) == "path id: not an integer"
# POST /notes '{"text": "hi"}', application/json -> 400 "Bad Request";
#   String(response.rejection().value()) == 'from_json: JSON member "txet" is missing'
# POST /notes '{', application/json -> 400 "Bad Request";
#   String(response.rejection().value()) == "json: invalid JSON: expected member name"
# GET /users/1 -> 200 "user 1"; response.rejection() is None
```

Run by `tests/test_rejection.mojo` (`test_errors_rejection_example`), as written; it reads the report on `TestClient`'s response and on `App.handle`'s. The other tests there check every step and message below; a middleware reading this report is in [middleware](middleware.md#logging-rejected-requests).

- `Response.rejection() -> Optional[Rejection]` returns a copy. `Rejection.step` is the step that refused the request; `name` is the route value's placeholder name for the first three, else empty:
  - `Rejection.PATH` (`"path"`): a path value's decoding or `Int` parse;
  - `Rejection.QUERY` (`"query"`): a query value missing, repeated, empty, or its decoding or `Int` parse; of a repeated key, the first whose second occurrence the query reaches;
  - `Rejection.FROM_ROUTE_VALUE` (`"from_route_value"`): that conversion raised;
  - `Rejection.UTF8` (`"utf-8"`): a text or `Json[T]` body that is not UTF-8;
  - `Rejection.JSON` (`"json"`): a `Json[T]` body that is not one JSON value;
  - `Rejection.FROM_BODY`, `Rejection.FROM_BYTES`, `Rejection.FROM_JSON` (`"from_body"`, `"from_bytes"`, `"from_json"`): that conversion raised.
- `message` is Muntin's own fixed text for `PATH`, `QUERY`, `UTF8` and `JSON`, and never holds a byte of the request: `missing`, `repeated`, `empty`, `bad percent escape`, `truncated percent escape`, `not UTF-8`, `not an integer`, `out of Int range`, or the JSON parser's message. For a `FROM_` step it is the raised error's text, which may hold client input: Mojo's `Int(text)` quotes its text. `JsonValue`'s own errors quote none, and `value[name]` names the missing member. A `Rejection` writes itself as `step name: message`, or `step: message` without a name.
- **A 400 is not always the client's fault**: a conversion that fails for a server-side reason (a missing configuration in `from_body`) is a 400 whose `Rejection` holds its message, and only that message tells it from bad input. `failure()` is `None` on every 400.
- A [guarded group](groups.md)'s route answers its guard first: a refused request has the guard's response and no `Rejection`; an admitted one gets its 400 with the report. A `WithHeaders[B]` body reports the steps of `B`.
- `None` on 404, 405, 413, 415, a backend's own 400 and the application's own responses. The report stays with the response through copies, `HEAD` and edits; a response built anew has none. No backend sends it.
- **`message` is not safe log text** for a `FROM_` step, as for a `Failure`; escaping and masking are the application's. An application does not build a `Rejection` (its initializer takes only `_`-prefixed keywords).
