# Must not build. Evidence for docs/reference/state.md, "Which state types
# compile" (M3-074): a static origin is refused inside a type argument too,
# although the value owns its data. `StaticString` prints its origin as `{}`
# wherever it appears in the name, here `ArcPointer[StringSpan[False, {}, {}]]`.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: std.memory.arc_pointer.ArcPointer[std.collections.string.string_span.StringSpan[False, {}, {}]]
from std.memory import ArcPointer
from muntin import State


def main():
    var state = State(ArcPointer(StaticString("static")))
    _ = state^
