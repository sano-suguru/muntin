# Must not compile (M3-002): `Headers` is copied explicitly with `.copy()`,
# like `Request` and `State`; assignment does not copy implicitly.
# Expected diagnostic (checked by scripts/check.sh): value of type 'Headers' cannot be implicitly copied
from headers_spike import Headers


def main():
    var a = Headers()
    var b = a
    _ = a^
    print(len(b))
