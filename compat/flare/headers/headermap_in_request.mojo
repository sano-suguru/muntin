# Must not compile (M3-002, candidate D): Flare's `HeaderMap` cannot be the
# headers field of Muntin's `Request`, which is `Copyable` (handlers and
# tests copy requests): `HeaderMap` is `Movable` only. Besides, a Flare type
# in `Request` would leak the backend into the public API (ARCHITECTURE A1).
# Expected diagnostic (checked by scripts/check_flare.sh): cannot synthesize copy constructor because field 'headers' has non-copyable type 'HeaderMap'
from flare.http import HeaderMap


struct FlareHeadersRequest(Copyable, Movable):
    var headers: HeaderMap

    def __init__(out self):
        self.headers = HeaderMap()


def main():
    var a = FlareHeadersRequest()
    var b = a.copy()
    print(b.headers.len())
