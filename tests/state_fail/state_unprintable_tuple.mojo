# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": `Tuple` is refused whatever its elements, since
# its name prints them as `<unprintable>` (beside a `{}`) and cannot show what
# they hold. A struct with the same fields is fine.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type has an origin parameter (printed {}) or one Mojo cannot print, so it may borrow a value the App outlives: std.builtin.tuple.Tuple[<unprintable>, {}]
from muntin import State


def main():
    var state = State(Tuple(1, String("a")))
    _ = state^
