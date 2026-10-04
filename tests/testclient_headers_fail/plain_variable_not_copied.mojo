# Must not compile (M3-010): the client takes the headers by move, as
# `Request`'s initializer does, so a caller passes `headers=headers^` or an
# explicit `headers=headers.copy()`; a plain variable is not copied silently
# (the rejected borrowed candidate would accept it and copy).
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied
from muntin import App, Headers
from testclient_headers_spike import SpikeClient


def main() raises:
    var app = App()
    var client = SpikeClient(app)
    var h = Headers()
    h.add("X-A", "1")
    _ = client.post("/x", "b", headers=h)
