# Must not compile (M3-008): a default decoder can build `Self` only through
# `Defaultable` (then overwrite fields), so every application type would need
# a dummy zero-argument initializer; without one, the error appears at the
# first use.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a derived decoder needs Defaultable
from std.builtin.rebind import downcast


trait FromFields(Movable):
    @staticmethod
    def build() -> Self:
        comptime assert conforms_to(
            Self, Defaultable
        ), "a derived decoder needs Defaultable"
        return rebind_var[Self](downcast[Self, Defaultable]())


@fieldwise_init
struct CreateUser(FromFields):
    var name: String


def main():
    _ = CreateUser.build()
