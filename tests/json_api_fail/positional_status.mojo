# Must not compile (M3-029): `Json`'s `status` is keyword-only, so
# `Json(value, 201)` matches no initializer; `Json(value, status=201)`
# compiles. The candidate note prints the initializer's signature.
# Expected diagnostic (checked by scripts/check.sh): def __init__(out self, var value: Self.T, *, status: Int = 200)
from muntin import App, Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var id: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.int(self.id)


def create() -> Json[Out]:
    return Json(Out(1), 201)


def main():
    var app = App()
    app.get["/out"](create)
