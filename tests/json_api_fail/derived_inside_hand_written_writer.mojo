# Must not compile (M3-083): a hand-written `write_json` cannot write a
# `JsonFields` value; `JsonWriter` takes `ToJson` types only, and derived
# types inside hand-written codecs are outside M3-082's slice.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import App, Json, JsonFields, JsonWriter, ToJson


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String


@fieldwise_init
struct Envelope(ToJson):
    var place: Place

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("place", self.place)
        out.end_object()


def h() -> Json[Envelope]:
    return Json(Envelope(Place("X")))


def main():
    var app = App()
    app.get["/c"](h)
