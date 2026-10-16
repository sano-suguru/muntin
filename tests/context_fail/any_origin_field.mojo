# Must not build. Evidence for docs/history/architecture-decisions.md, "Request
# context storage decision (M3-065)": a context type the application declares
# cannot name `AnyOrigin` in a field's type, so a field cannot accept a view of
# any local (tests/context_fail/local_origin_into_field.mojo). A struct
# parameter can still be instantiated with it, the toolchain-wide hole of
# tests/registration_known_gaps/safe_dangling_any_origin_slice.mojo.
# Expected diagnostic (checked by scripts/check.sh): struct fields cannot expose AnyOrigin in their type


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


struct Session(Movable):
    var view: Optional[View[ImmutAnyOrigin]]

    def __init__(out self):
        self.view = None


def main():
    var session = Session()
    _ = session^
