# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a closure that captures a local by reference
# carries its origin in its type (`__storage[{}]`), and is refused.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_origin_closure.main().read_token.__storage[{}]

from std.memory import OwnedPointer

from muntin import State


def main():
    var token = OwnedPointer(42)

    def read_token() {imm token} -> Int:
        return token[]

    var state = State(read_token^)
    _ = state^
