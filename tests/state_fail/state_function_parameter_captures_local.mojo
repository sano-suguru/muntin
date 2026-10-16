# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a function-valued parameter, which the rule
# admits although its name prints as `<unprintable>`, cannot carry a local:
# a closure that captures one is a runtime value, and Mojo 1.1.0 refuses it
# as a parameter before `State` sees the type.
# Expected diagnostic (checked by scripts/check.sh): cannot use a dynamic value in a parameter list

from std.memory import OwnedPointer

from muntin import State


struct Run[f: def() -> Int](Movable):
    def __init__(out self):
        pass


def main():
    var token = OwnedPointer(42)

    def read_token() {imm token} -> Int:
        return token[]

    var state = State(Run[read_token]())
    _ = state^
