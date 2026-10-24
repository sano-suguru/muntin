# Must not compile (M3-075): `field` and `value` cover one level of
# `Optional` or `List` around a supported type; a `List[List[Int]]` (or an
# `Optional[List[...]]`) is written with an explicit loop, as before.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Grid(ToJson):
    var rows: List[List[Int]]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("rows", self.rows)
        out.end_object()


def main() raises:
    print(Json(Grid(List[List[Int]]())).to_response().text())
