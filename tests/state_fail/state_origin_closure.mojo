# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a closure that captures a local by reference carries its
# origin in its type, and is refused; one that captures by value owns what it
# holds.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type has an origin parameter (printed {}) or one Mojo cannot print, so it may borrow a value the App outlives: state_origin_closure.main().read_token.__storage[{}]

from std.memory import OwnedPointer

from muntin import State


def main():
    var token = OwnedPointer(42)

    def read_token() {imm token} -> Int:
        return token[]

    var state = State(read_token^)
    _ = state^
