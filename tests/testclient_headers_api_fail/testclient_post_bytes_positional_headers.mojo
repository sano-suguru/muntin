# Must not compile (M3-040): `TestClient.post`'s bytes overload takes its
# header fields keyword-only, as the text overload does; a positional
# `Headers` after a bytes body is rejected by both candidates.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'post'
from muntin import App, Headers
from muntin.testing import TestClient


def main():
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    _ = client.post("/x", List[UInt8](), h^)
