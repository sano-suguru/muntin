# Must not compile (M3-005): `add` validates and raises, so code that sets
# a header either handles the error or raises itself (a raising handler's
# error is the fixed 500 or its ToErrorResponse).
# Expected diagnostic (checked by scripts/check.sh): cannot call function that may raise in a context that cannot raise
from muntin import Headers


def build() -> Int:
    var h = Headers()
    h.add("X-A", "1")
    return len(h)


def main():
    _ = build()
