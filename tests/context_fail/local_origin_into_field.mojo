# Must not build. Evidence for docs/history/architecture-decisions.md, "Request
# context storage decision (M3-065)": a context value written into a field of a
# context type the application declares keeps its origin, so a view of a local
# cannot be stored where the field's type promises a longer-lived one. Erased
# storage accepts the same write (tests/context_known_gaps/erasure_drops_origin.mojo).
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'View[origin_of(token["value"])]' value to 'Optional[View[ImmStaticOrigin]]'
from std.memory import OwnedPointer


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


struct Session(Movable):
    var view: Optional[View[ImmStaticOrigin]]

    def __init__(out self):
        self.view = None


def middleware(mut session: Session):
    var token = OwnedPointer(42)
    session.view = View(token[])


def main():
    var session = Session()
    middleware(session)
