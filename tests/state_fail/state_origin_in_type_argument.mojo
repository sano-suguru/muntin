# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": an origin inside a type argument (`Box[View[o]]`)
# is refused like a direct one (state_origin_local_get.mojo). Built against the
# base it registers, as #122's reproductions did.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_origin_in_type_argument.Box[state_origin_in_type_argument.View[{}, {}]]

from std.memory import OwnedPointer

from muntin import App, State


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


struct Box[T: Movable & Deinitable](Movable):
    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^


def show[o: Origin[mut=False]](box: State[Box[View[o]]]) -> String:
    return String(box[].value.p[])


def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](show[origin_of(token[])], State(Box(View(token[]))))


def main():
    var app = App()
    build(app)
