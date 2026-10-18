# Must not build. Evidence for docs/reference/state.md, "Which state types
# compile" (M3-074): a struct value with no fields as a parameter prints as
# `{}`, so the rule takes it for an origin; a struct value with a field
# (tests/test_state.mojo, `Tuned[Mode.FAST]`) prints otherwise and registers.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_empty_struct_parameter.Config[{}]
from muntin import State


@fieldwise_init
struct Flag(Equatable, ImplicitlyCopyable, Movable):
    pass


struct Config[flag: Flag](Movable):
    def __init__(out self):
        pass


def main():
    var state = State(Config[Flag()]())
    _ = state^
