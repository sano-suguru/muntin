# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a function-valued parameter's result type is
# concrete, so a field typed by it names a local's origin through a parameter
# of the struct (here the inferred `R`), which prints (`{}`). Built against
# the base it registers, and its request reads the dropped local.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_origin_in_function_result_type.Hidden[std.collections.optional.Optional[std.memory.pointer.Pointer[False, {}, SIMD[DType.int, 1], {}, 0]], <unprintable>]

from std.memory import OwnedPointer

from muntin import App, State


def null_view[o: Origin[mut=False]]() -> Optional[Pointer[Int, o]]:
    return None


def view_of[o: Origin[mut=False]](ref[o] x: Int) -> Optional[Pointer[Int, o]]:
    return Pointer(to=x)


struct Hidden[R: Movable & Deinitable, //, f: def() thin -> R](Movable):
    var p: Self.R

    def __init__(out self, var p: Self.R):
        self.p = p^


def show[o: Origin[mut=False]](h: State[Hidden[null_view[o]]]) -> String:
    return String(h[].p.value()[])


def hidden[o: Origin[mut=False]](ref[o] x: Int) -> State[Hidden[null_view[o]]]:
    return State(Hidden[null_view[o]](view_of(x)))


def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](show[origin_of(token[])], hidden(token[]))


def main():
    var app = App()
    build(app)
