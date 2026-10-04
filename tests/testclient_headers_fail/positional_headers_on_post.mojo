# Must not compile (M3-010): `post`'s header fields are keyword-only, as on
# `get`; a positional third argument is rejected.
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'post': unexpected argument
from muntin import App, Headers
from testclient_headers_spike import SpikeClient


def main():
    var app = App()
    var client = SpikeClient(app)
    var h = Headers()
    _ = client.post("/x", "b", h^)
