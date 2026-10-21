# Must not compile (M3-082 prototype): a ToJson-only field in a body.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field shown of the JsonFields struct derived_write_only_in_body.In has type derived_write_only_in_body.Shown, which cannot be read
from muntin import App, Json, JsonFields, JsonWriter, ToJson


@fieldwise_init
struct Shown(Copyable, ToJson):
    var city: String

    def write_json(self, mut out: JsonWriter) raises:
        out.string(self.city)


@fieldwise_init
struct In(JsonFields):
    var shown: Shown


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
