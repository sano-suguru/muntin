# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": the rule reads the type, not the value, so a
# static origin is refused too (`StaticString` as the whole state). A field
# holding one is fine: tests/test_state.mojo's `Label`.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type has an origin parameter (printed {}) or one Mojo cannot print, so it may borrow a value the App outlives: std.collections.string.string_span.StringSpan[False, {}, {}]
from muntin import State


def main():
    var state = State(StaticString("static"))
    _ = state^
