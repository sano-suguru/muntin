# Must not compile (M3-083): a UInt8 field of a struct in an Optional field of
# a body; the message names the innermost field, not the field holding it.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field zip of the JsonFields struct derived_nested_struct_body.Place has type SIMD[DType.uint8, 1], which cannot be read
from muntin import App, Json, JsonFields


@fieldwise_init
struct Place(JsonFields):
    var city: String
    var zip: UInt8


@fieldwise_init
struct In(JsonFields):
    var home: Optional[Place]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
