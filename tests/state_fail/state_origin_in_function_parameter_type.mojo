# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a function-valued parameter's type is built
# from the struct's other parameters, so a local's origin in it is one of
# them and prints (`{}`); the field that holds the pointer the function reads
# needs that parameter too.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_origin_in_function_parameter_type.Reader[{}, {}, <unprintable>]

from std.memory import OwnedPointer

from muntin import App, State


def deref[o: Origin[mut=False]](p: Pointer[Int, o]) -> Int:
    return p[]


struct Reader[o: Origin[mut=False], f: def(Pointer[Int, o]) thin -> Int](
    Movable
):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def show[o: Origin[mut=False]](reader: State[Reader[o, deref[o]]]) -> String:
    return String(reader[].f(reader[].p))


def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](
        show[origin_of(token[])],
        State(Reader[origin_of(token[]), deref[origin_of(token[])]](token[])),
    )


def main():
    var app = App()
    build(app)
