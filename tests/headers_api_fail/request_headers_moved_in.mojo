# Must not compile (M3-005): `Request`'s initializer takes the headers by
# move (`var headers`), so a caller transfers them with `^` or passes an
# explicit `.copy()`; a plain variable is not copied implicitly.
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied
from muntin import Headers, Request


def main():
    var h = Headers()
    var req = Request("GET", "/x", "", h)
    print(len(req.headers), len(h))
