# Must not compile: an exact `-> StaticString` overload beside a generic
# result overload does not let a `String` handler fall through to the
# generic one; the call fails on the exact candidate. So the selected
# design cannot keep `StaticString` exact by giving it its own overload
# (docs/ARCHITECTURE.md, "Registration structure decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'String' value to 'StringSpan[ImmStaticOrigin]'


struct Registrar:
    def __init__(out self):
        pass

    def on[
        E: Deinitable, //
    ](mut self, handler: def() thin raises E -> StaticString):
        pass

    def on[
        E: Deinitable, R: Movable & Deinitable, //
    ](mut self, handler: def() thin raises E -> R):
        pass


def text() -> String:
    return "x"


def main():
    var reg = Registrar()
    reg.on(text)
