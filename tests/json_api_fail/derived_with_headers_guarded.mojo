# Must not compile (M3-083): a carried `List` of derived structs in a guarded
# group's route is refused at the registration, naming the innermost field.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field at of the JsonFields struct derived_with_headers_guarded.Inner has type SIMD[DType.float16, 1], which cannot be read
from muntin import (
    App,
    Group,
    Headers,
    Json,
    JsonFields,
    Response,
    State,
    ToErrorResponse,
    WithHeaders,
)


@fieldwise_init
struct Inner(Copyable, JsonFields):
    var at: Float16


@fieldwise_init
struct Outer(Copyable, JsonFields):
    var inner: List[Inner]


@fieldwise_init
struct Who(Movable):
    var name: String


struct Denied(Movable, ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("Unauthorized", status=401)


def guard(keys: State[String], headers: Headers) raises Denied -> Who:
    return Who("ada")


def h(who: Who, id: Int, input: WithHeaders[Json[List[Outer]]]) -> String:
    return "x"


def main():
    var app = App()
    var g = Group(guard, State(String("k")))
    g.post["/c/{id}"](h)
    app.mount(g^)
