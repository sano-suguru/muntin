# Must not compile: a call no overload accepts, on a method with eleven
# overloads whose candidate notes carry no detail notes. Mojo 1.1.0 prints
# at most ten notes per diagnostic, so the eleventh candidate's note
# ('UInt32') is omitted. This is the budget that keeps typed header access
# off App.get (docs/ARCHITECTURE.md, "Typed header access decision
# (M3-012)"): get and post already have ten overloads each. If the cap
# rises, the omission marker disappears and this check fails; revisit then.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'Other' to 'UInt16' (1 more notes omitted.)


struct Registry:
    def __init__(out self):
        pass

    def take(self, value: Int):
        pass

    def take(self, value: String):
        pass

    def take(self, value: Bool):
        pass

    def take(self, value: Float64):
        pass

    def take(self, value: UInt8):
        pass

    def take(self, value: Int8):
        pass

    def take(self, value: Int16):
        pass

    def take(self, value: Int32):
        pass

    def take(self, value: Int64):
        pass

    def take(self, value: UInt16):
        pass

    def take(self, value: UInt32):
        pass


struct Other:
    def __init__(out self):
        pass


def main():
    var r = Registry()
    r.take(Other())
