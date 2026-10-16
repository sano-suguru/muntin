# Must not build. Evidence for docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": a view of a local inside a `Variant` is
# refused. Like a `Tuple`, its pack's element types do not print, so only the
# `{}` Mojo 1.1.0 prints beside every pack refuses it.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: std.utils.variant.Variant[<unprintable>, {}]

from std.memory import OwnedPointer
from std.utils import Variant

from muntin import App, State


struct View[o: Origin[mut=False]](ImplicitlyCopyable, Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def show[o: Origin[mut=False]](views: State[Variant[View[o]]]) -> String:
    return String(views[][View[o]].p[])


def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](
        show[origin_of(token[])],
        State(Variant[View[origin_of(token[])]](View(token[]))),
    )


def main():
    var app = App()
    build(app)
