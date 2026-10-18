# Must not compile (M3-075): `JsonWriter.field` takes Int, Float64, Bool,
# String, a `ToJson` type, and an `Optional` or `List` of one of those. A
# struct that does not conform to `ToJson` fails where `field` is called,
# not deeper in an instantiation.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'field'
from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Address(Copyable):  # no ToJson
    var zip: Int


@fieldwise_init
struct User(ToJson):
    var home: Address

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("home", self.home)
        out.end_object()


def main() raises:
    print(Json(User(Address(1))).to_response().text())
