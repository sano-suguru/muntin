# Must not compile (M3-010): `headers^` moves the fields into the request;
# the variable cannot be used afterwards (pass `headers.copy()` to keep it).
# Expected diagnostic (checked by scripts/check.sh): use of uninitialized value 'h'
from muntin import App, Headers
from testclient_headers_spike import SpikeClient


def main() raises:
    var app = App()
    var client = SpikeClient(app)
    var h = Headers()
    h.add("X-A", "1")
    _ = client.get("/x", h^)
    print(len(h))
