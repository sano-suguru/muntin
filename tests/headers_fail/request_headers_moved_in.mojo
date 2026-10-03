# Must not compile (M3-002): `Request`'s initializer takes the headers by
# move (`var headers`), so a caller transfers them with `^` or passes an
# explicit `.copy()`; a plain variable is not copied implicitly.
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied
from headers_spike import HRequest, Headers


def main():
    var h = Headers()
    var req = HRequest("GET", "/x", "", h)
    print(len(req.headers), len(h))
