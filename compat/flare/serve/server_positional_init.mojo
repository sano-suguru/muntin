# Must not compile (M3-032): `Server` has no positional initializer;
# `Server.bind(host, port)` is its one public spelling. If this builds,
# revisit whether `Server` has one public spelling.
# Expected diagnostic (checked by scripts/check_flare.sh): no matching function in initialization
from muntin_flare import Server


def main() raises:
    _ = Server("127.0.0.1", 0)
