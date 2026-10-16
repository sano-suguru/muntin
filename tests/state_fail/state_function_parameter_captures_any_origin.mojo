# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a closure that captures, by value, a pointer
# to a local built with `ImmutAnyOrigin` is a runtime value too, so it cannot
# become a function-valued parameter and hide the pointer from the name.
# Expected diagnostic (checked by scripts/check.sh): cannot use a dynamic value in a parameter list

from std.memory import OwnedPointer

from muntin import State


struct Run[f: def() -> Int](Movable):
    def __init__(out self):
        pass


def main():
    var token = OwnedPointer(42)
    var p = Pointer[Int, ImmutAnyOrigin](to=token[])

    def read_token() {var p} -> Int:
        return p[]

    var state = State(Run[read_token]())
    _ = state^
