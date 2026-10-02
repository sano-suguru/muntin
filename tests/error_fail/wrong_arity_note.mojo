# Must not compile: a two-parameter handler on `get`, which has no
# overload for it (M2-010). Pins how the compiler spells the inferred error type in a
# candidate note: a non-raising handler fixes `E = Never`, so the notes of
# the overloads that production would widen read `raises Never`, and every
# fixture that checks such a note changes text with the production slice.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def pair(a: Int, b: Int) thin -> String' to 'def(Int) raises Never thin -> String'

from error_spike import ErrorApp


def pair(a: Int, b: Int) -> String:
    return "pair"


def main():
    var app = ErrorApp()
    app.get["/users/{a}/{b}"](pair)
