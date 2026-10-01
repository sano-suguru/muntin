# Must not compile: a Variant arm with no dispatch branch, when dispatch loops
# over the arm types at compile time (production App.handle instead ends its
# `isa` chain in a run-time `abort`).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Variant arm without a dispatch branch

from std.utils import Variant

comptime _NoArgs = def() thin -> String
comptime _IntArg = def(Int) thin -> String
comptime _StrArg = def(String) thin -> String
comptime _Handler = Variant[_NoArgs, _IntArg, _StrArg]


def dispatch(h: _Handler, x: Int) -> String:
    comptime for i in range(_Handler.Ts.length):
        comptime T = _Handler.Ts[i]
        if h.isa[T]():
            comptime if T == _NoArgs:
                return h[_NoArgs]()
            elif T == _IntArg:
                return h[_IntArg](x)
            else:
                comptime assert False, "Variant arm without a dispatch branch"
    return ""


def hello() -> String:
    return "hello"


def main():
    print(dispatch(_Handler(hello), 1))
