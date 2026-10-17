# Must not compile (M3-075): an integer list literal passed to `field`
# converts to both `List[Int]` and `List[Float64]`. A typed field or
# `var ids: List[Int] = [1, 2]` chooses one.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Ids(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("ids", [1, 2])
        out.end_object()


def main() raises:
    print(Json(Ids()).to_response().text())
