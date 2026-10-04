# Must not compile (M3-010): `get`'s optional second argument is the header
# fields; a GET request has no body argument, so a string there is rejected.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'StringLiteral["b"]' to 'Headers'
from muntin import App
from testclient_headers_spike import SpikeClient


def main():
    var app = App()
    var client = SpikeClient(app)
    _ = client.get("/x", "b")
