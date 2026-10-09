# Must not compile: `TestClient.head`'s header fields are keyword-only, as on
# `get` and the other methods (M3-010); a positional `Headers` is rejected.
# Decision: docs/history/architecture-decisions.md, "TestClient HEAD decision
# (M3-036)".
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'head': unexpected argument
from muntin import App, Headers
from muntin.testing import TestClient


def main():
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    _ = client.head("/x", h^)
