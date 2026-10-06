# Must not compile: `TestClient.patch`'s header fields are keyword-only, as on
# `get` and `post` (M3-011); a positional `Headers` is rejected. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'patch': unexpected argument
from muntin import App, Headers
from muntin.testing import TestClient


def main():
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    _ = client.patch("/x", "b", h^)
