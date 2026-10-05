# Must not compile (M3-009): production `Json[T]` is a result only when `T`
# conforms to `ToJson`; otherwise the result is outside every `get` overload's
# `where` clause (M3-015).
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])
from muntin import App, FromJson, Json, JsonValue


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
