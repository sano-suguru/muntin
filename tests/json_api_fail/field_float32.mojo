# Must not compile (M3-075): `field` takes `Float64`, not other float widths; a
# `Float32` is converted first (`Float64(x)`), as for `JsonWriter.float`.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var x: Float32

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("x", self.x)
        out.end_object()


def main() raises:
    pass
