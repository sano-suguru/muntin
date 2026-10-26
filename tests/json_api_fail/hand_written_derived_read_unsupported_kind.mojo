# Must not compile (M3-087): `JsonValue.read` of a kind no derived field
# takes fails at the call, naming the type, not `Json[T]`.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: SIMD[DType.uint8, 1] cannot be read: a derived value is an Int, Float64, Bool, String, a FromJson type
from muntin import App, FromJson, Json, JsonValue


@fieldwise_init
struct Small(FromJson):
    var n: UInt8

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[UInt8]())


def h(body: Json[Small]) -> String:
    return String(body.value.n)


def main():
    var app = App()
    app.post["/c"](h)
