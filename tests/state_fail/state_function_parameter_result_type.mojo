# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a field type cannot be derived from what a
# function-valued parameter returns unless that parameter's type is a
# function type, whose result type must then be concrete (state_origin_in_
# function_result_type.mojo, state_function_parameter_open_result.mojo). A
# parameter of an open type (`F: AnyType`), whose name would hide a local's
# origin (`__MLIRType[<unprintable>]`), cannot be called: Mojo 1.1.0 refuses
# `type_of(Self.f())` before `State` sees the type.
# Expected diagnostic (checked by scripts/check.sh): 'F' does not implement the '__call__' method

from std.memory import OwnedPointer

from muntin import App, State


def null_view[o: Origin[mut=False]]() -> Optional[Pointer[Int, o]]:
    return None


struct Hidden[F: AnyType, //, f: F](Movable):
    comptime P = type_of(Self.f())
    var p: Self.P

    def __init__(out self, var p: Self.P):
        self.p = p^


def show[o: Origin[mut=False]](h: State[Hidden[null_view[o]]]) -> String:
    return String(h[].p.value()[])


def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](
        show[origin_of(token[])],
        State(Hidden[null_view[origin_of(token[])]](Pointer(to=token[]))),
    )


def main():
    var app = App()
    build(app)
