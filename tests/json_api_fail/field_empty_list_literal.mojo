# Must not compile (M3-075): an empty list literal passed to `field` is ambiguous
# between the `List` overloads; a typed value (`List[String]()`) chooses one.
# Expected diagnostic (checked by scripts/check.sh): ambiguous call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Out(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("xs", [])
        out.end_object()


def main() raises:
    pass
