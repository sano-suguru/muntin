# Must not compile (M3-075): `field` covers one level of `Optional` or `List`; an
# `Optional[List[Int]]` is written with an explicit array, as before.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    var tags: Optional[List[Int]]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("tags", self.tags)
        out.end_object()


def main() raises:
    pass
