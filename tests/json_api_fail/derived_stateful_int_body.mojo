# Must not compile (M3-083): a Float16 field, stateful put with a route value.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field at of the JsonFields struct derived_stateful_int_body.In has type SIMD[DType.float16, 1], which cannot be read
from muntin import App, Json, JsonFields, State


@fieldwise_init
struct In(JsonFields):
    var at: Float16


def h(s: State[Int], id: Int, body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.put["/c/{id}"](h, State(1))
