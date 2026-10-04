# Must not compile (M3-009): every production `JsonWriter` call raises
# (structure, non-finite numbers), so a `ToJson` conformer's `write_json`
# must be `raises`; a non-raising implementation that writes does not
# compile.
# Expected diagnostic (checked by scripts/check.sh): cannot call function that may raise in a context that cannot raise
from muntin import App, Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var id: Int

    def write_json(self, mut out: JsonWriter):
        out.int(self.id)


def show() -> Json[Out]:
    return Json(Out(1))


def main():
    var app = App()
    app.get["/out"](show)
