# Must not compile (M3-082 prototype): a raw from_body, refused by the codec.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field by_name of the JsonFields struct derived_raw_from_body.Counts has type
from muntin import Json, JsonFields


@fieldwise_init
struct Counts(JsonFields):
    var by_name: Dict[String, Int]


def main() raises:
    _ = Json[Counts].from_body("{}")
