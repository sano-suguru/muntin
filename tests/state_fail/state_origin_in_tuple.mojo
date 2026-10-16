# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a view of a local inside a `Tuple` is refused.
# The pack's element types do not print (`<unprintable>`), so only the `{}`
# Mojo 1.1.0 prints beside every pack refuses it; if this file builds, packs
# stopped printing it and a borrowing pack registers again. Built against the
# base it registers, as #122's reproductions did.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: std.builtin.tuple.Tuple[<unprintable>, {}]

from std.memory import OwnedPointer

from muntin import App, State


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def show[o: Origin[mut=False]](views: State[Tuple[View[o]]]) -> String:
    return String(views[][0].p[])


def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](show[origin_of(token[])], State(Tuple(View(token[]))))


def main():
    var app = App()
    build(app)
