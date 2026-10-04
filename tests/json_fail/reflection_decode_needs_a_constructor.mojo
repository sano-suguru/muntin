# Must not compile (M3-008): a default `from_json` cannot build `Self` from
# reflected fields: `std.reflection` gives field access, not a constructor,
# so a reflection-derived decoder needs `Defaultable` (a dummy initializer
# in every application type) or unsafe uninitialized storage.
# Expected diagnostic (checked by scripts/check.sh): invalid initialization: missing required argument: 'move'
trait FromFields(Movable):
    @staticmethod
    def build() raises -> Self:
        var out = Self()
        return out^


@fieldwise_init
struct CreateUser(FromFields):
    var name: String


def main() raises:
    _ = CreateUser.build()
