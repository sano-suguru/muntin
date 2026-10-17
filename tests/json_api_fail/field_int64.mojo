# Must not compile (M3-075): `field` takes `Int`, not other integer widths; an
# `Int64` is converted first (`Int(n)`), as for `JsonWriter.int`.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var n: Int64

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("n", self.n)
        out.end_object()


def main() raises:
    pass
