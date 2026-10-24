# Must not compile (M3-087 prototype): a hand-written from_json reads a JsonFields struct whose field
# cannot be read; the build fails at the call, naming the field.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field zip of the JsonFields struct hand_written_derived_reader_names_field.Place has type SIMD[DType.uint8, 1], which cannot be read
from muntin import App, FromJson, Json, JsonFields, JsonValue


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String
    var zip: UInt8


@fieldwise_init
struct Envelope(FromJson):
    var place: Place

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[Place]("place"))


def h(body: Json[Envelope]) -> String:
    return body.value.place.city


def main():
    var app = App()
    app.post["/c"](h)
