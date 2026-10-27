# Must not compile (M3-087): `JsonValue.read` of a kind no derived field
# takes fails at the call, naming the type, not `Json[T]`.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: SIMD[DType.float16, 1] cannot be read: a derived value is an Int, UInt, sized integer, Float64, Float32, Bool, String, a FromJson type
from muntin import App, FromJson, Json, JsonValue


@fieldwise_init
struct Small(FromJson):
    var n: Float16

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[Float16]())


def h(body: Json[Small]) -> String:
    return String(body.value.n)


def main():
    var app = App()
    app.post["/c"](h)
