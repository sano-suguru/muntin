# Must not compile (M3-005): `Headers` is copied explicitly with `.copy()`,
# like `Request` and `State`; assignment does not copy implicitly.
# Expected diagnostic (checked by scripts/check.sh): value of type 'Headers' cannot be implicitly copied
from muntin import Headers


def main():
    var a = Headers()
    var b = a
    _ = a^
    print(len(b))
