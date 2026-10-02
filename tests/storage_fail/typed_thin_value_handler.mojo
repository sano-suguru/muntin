# Must not compile on Mojo 1.1.0 since M2-011 (compiled on M2-010 main): a
# handler value whose type is spelled without `raises` does not convert to
# the overloads' `def() thin raises E -> String` with `E` inferred. A plain
# `def` handler does. Measured limitation, not a design choice: raising
# twins beside the overloads are ambiguous
# (tests/error_fail/raising_twin_overloads.mojo). Workarounds: spell the
# value's type `def() thin raises Never -> String`, or make a forwarding
# helper generic over `E: Deinitable`. If this compiles, revisit
# docs/ARCHITECTURE.md "Raising handlers in production (M2-011)".
# Expected diagnostic (checked by scripts/check.sh): TODO: function type conversions between closures not supported yet

from muntin import App


def hello() -> String:
    return "hello"


def main():
    var app = App()
    var handler: def() thin -> String = hello
    app.get["/hello"](handler)
