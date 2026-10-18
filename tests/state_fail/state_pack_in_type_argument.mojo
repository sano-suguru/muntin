# Must not build. Evidence for docs/reference/state.md, "Which state types
# compile" (M3-074): an owned `Tuple` is refused as a type argument too
# (`Box[Tuple[<unprintable>, {}]]`). The migration names the tuple's type in
# a field of a non-generic struct (tests/test_state.mojo, `Pair`).
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_pack_in_type_argument.Box[std.builtin.tuple.Tuple[<unprintable>, {}]]
from muntin import State


struct Box[T: Movable & Deinitable](Movable):
    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^


def main():
    var state = State(Box(Tuple(1, String("a"))))
    _ = state^
