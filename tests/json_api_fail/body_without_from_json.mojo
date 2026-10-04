# Must not compile (M3-009): production `Json[T]` is a body only when `T`
# conforms to `FromJson` (conditional conformance); otherwise the existing
# `post` overloads reject it as not a `FromBody`, at the registration, with
# the existing message.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody
from muntin import App, Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var id: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.int(self.id)


def create(body: Json[Out]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/out"](create)
