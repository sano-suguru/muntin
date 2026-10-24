# Must build, never run (M3-087 prototype): a hand-written codec naming a
# `JsonFields` struct with a field that cannot be read or written builds
# while nothing instantiates the codec; the `comptime assert` of
# `JsonWriter.field` and `JsonValue.read` fires only when a route or a call
# uses it (tests/json_api_fail/hand_written_derived_*_names_field.mojo),
# because a `where` clause cannot call the refusal on Mojo 1.1.0. If this
# stops building, the refusal can come at the call: re-measure.
from muntin import FromJson, JsonFields, JsonValue, JsonWriter, ToJson


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String
    var zip: UInt8


@fieldwise_init
struct Envelope(Copyable, FromJson, ToJson):
    var place: Place

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[Place]("place"))

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("place", self.place)
        out.end_object()


def main():
    pass
