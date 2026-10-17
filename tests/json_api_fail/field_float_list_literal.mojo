# Must not compile (M3-075): a float list literal passed to `field` is ambiguous:
# the call has `Int`, `Float64`, `List[Int]` and `List[Float64]` candidates. A
# typed value (`var xs: List[Float64] = [1.5]`) chooses one.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("xs", [1.5])
        out.end_object()


def main() raises:
    pass
