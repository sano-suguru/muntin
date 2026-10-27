# Must not compile (M3-087): a hand-written `write_json` writes a
# `JsonFields` struct with a field that cannot be written; the build fails
# at the call when the route instantiates the codec, naming the field.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field zip of the JsonFields struct hand_written_derived_writer_names_field.Place has type SIMD[DType.uint8, 1], which cannot be written
from muntin import App, Json, JsonFields, JsonWriter, ToJson


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String
    var zip: UInt8


@fieldwise_init
struct Envelope(ToJson):
    var place: Place

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("place", self.place)
        out.end_object()


def h() -> Json[Envelope]:
    return Json(Envelope(Place("X", 1)))


def main():
    var app = App()
    app.get["/c"](h)
