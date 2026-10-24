# Must not compile (M3-075): `field` covers one level of `Optional` or `List`; a
# `List[Optional[Int]]` is written with an explicit loop, as before.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var marks: List[Optional[Int]]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("marks", self.marks)
        out.end_object()


def main() raises:
    pass
