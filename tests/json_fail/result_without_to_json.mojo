# Must not compile (M3-008): `Json[T]` is a result only when `T` conforms to
# `ToJson`; otherwise no `get` overload accepts the handler.
# Expected diagnostic (checked by scripts/check.sh): argument type 'Json[In]' does not conform to trait 'ToResponse'
from muntin import App
from json_spike import FromJson, Json, JsonValue


@fieldwise_init
struct In(FromJson):
    var id: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.int())


def show() -> Json[In]:
    return Json(In(1))


def main():
    var app = App()
    app.get["/in"](show)
