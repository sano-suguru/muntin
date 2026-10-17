# Responses

A typed handler returns `String`, `StaticString` (a string literal included) or a type conforming to `ToResponse`, `Response` itself included. A raw handler returns `Response` ([raw handlers](raw.md)). Errors a handler raises are [errors](errors.md). Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

## Text results

`String` and `StaticString` results are 200 text responses with **no fields**: Muntin adds no `Content-Type` or other default field to them or to `Response.text`. Only `Json[T]` results add `Content-Type: application/json`.

## `ToResponse`

<!-- example: tests/test_reference_examples.mojo#responses-to-response -->
```mojo
from muntin import App, Response, ToResponse


@fieldwise_init
struct UserText(ToResponse):              # defined by the application; may be move-only
    var id: Int
    var name: String

    def to_response(deinit self) -> Response:   # the application chooses status and body
        var name = self.name^                    # moved, not copied
        return Response.text(String(self.id) + " " + name)


def get_user(id: Int) -> UserText:
    return UserText(id, "Ada")


def health() -> Response:                 # Response conforms itself
    return Response.text("ok")


var app = App()
app.get["/users/{id}"](get_user)          # unchanged registration syntax
app.get["/health"](health)
# GET /users/7  -> 200 "7 Ada", no fields
# GET /health   -> 200 "ok", no fields
```

Run by `tests/test_reference_examples.mojo` (`test_responses_to_response`), as written. `tests/test_response.mojo` (`test_user_result_converts_once_on_every_argument_shape`) checks that such a conversion runs once on every argument shape.

- The requirement is `def to_response(var self) -> Response`; an implementation may declare `self`, `var self` or `deinit self`. It does not raise.
- `Response` conforms and returns itself, so a handler's status, fields and body reach the client unchanged.
- The conversion runs once, after the handler returns. A 400, 404 or 405 calls neither the handler nor the conversion; a raise skips it.
- A result that is neither `String`, `StaticString` nor conforming fails at the registration: `no matching method in call to 'get'`, with `violated constraint` and the `where` clause in the candidate note. When the call does not let the compiler decide the clause (a local's immutable origin, or a forwarding helper whose generic result is not pinned down by its own `where`), the error is `invalid call to '<method>': lacking evidence to prove correctness` instead ([routing](routing.md#compile-time-diagnostics)). Other string slices (`StringSlice[ImmutAnyOrigin]`) are rejected.

## JSON results

A handler returns `Json[T]` with `T: ToJson` ([bodies](bodies.md#json-jsont) for `FromJson`/`ToJson`). The response is status 200 with exactly one field, `Content-Type: application/json`. `Json(value, status=201)` chooses another status. `CreateUser` (`FromJson`, with an optional `nickname`) and `User` (`ToJson`, written as `{"id":...,"name":...}`) are the types of [bodies](bodies.md#json-jsont), not the `UserText` above:

<!-- example: tests/test_json_dx.mojo#responses-json -->
```mojo
def register(var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()
    return Json(User(2, c.name), status=201)


var app = App()
app.post["/accounts"](register)
# POST /accounts  Content-Type: application/json  {"name":"Bo","age":1}
#   -> 201, Content-Type: application/json, {"id":2,"name":"Bo"}
```

Run by `tests/test_json_dx.mojo` (`test_json_result_status`), as written, with the types of [bodies](bodies.md#json-jsont).

- `status` is keyword-only (`Json(value, 201)` does not compile) and not validated.
- Another media type is an edit of the converted response:

<!-- example: tests/test_json_dx.mojo#responses-json-media-type -->
```mojo
def create() raises -> Response:
    var r = Json(User(7, "Ada"), status=201).to_response()
    r.headers.set("Content-Type", "application/problem+json")   # a set after the conversion wins
    return r^
```

Run by `tests/test_json_dx.mojo` (`test_dx_json_examples`), as written, registered at `GET /create`: 201, `{"id":7,"name":"Ada"}`, `Content-Type: application/problem+json`. `User` is the `ToJson` type of [bodies](bodies.md#json-jsont).

- If `write_json` raises (NaN and infinity included) or leaves the writer unbalanced, the answer is the fixed 500 without a `Content-Type`, whatever status was chosen, carrying a `Failure.RESPONSE` report ([errors](errors.md#reports-of-dropped-errors)); the handler's `ToErrorResponse` is not called. **An edit after `to_response()` applies to that 500 too**: a status set there (`r.status = 201`) would turn the failure into a success with the body `Internal Server Error`, so choose the status with `status=` ([why](../history/decisions/m3-028-json-response-status-decision.md)).
- The writer prints a `Float64` with `String(Float64)`, which does not always read back to the same double (Mojo 1.1.0).
- A top-level list is not a result: `List[User]` conforms to neither trait; return an application type that does.

## `Response`

- `Response(status, body)` takes text or bytes (`List[UInt8]`, moved); `Response.text(text, status=200)` stores the text's UTF-8 bytes. `response.body` is `List[UInt8]`; `response.text()` returns it as text and raises when it is not UTF-8.
- `response.headers` is a [`Headers`](headers.md), empty from both constructors.
- `response.failure()` is the report on the fixed 500 ([errors](errors.md#reports-of-dropped-errors)).
- Muntin does not validate a status.
