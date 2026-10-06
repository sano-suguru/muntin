# Must not compile: `TestClient.delete` takes the header fields by move, as on
# `get` and `post` (M3-011), so a plain variable is not copied silently.
# Decision: docs/history/architecture-decisions.md, "HTTP methods decision
# (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied
from muntin import App, Headers
from muntin.testing import TestClient


def main() raises:
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-A", "1")
    _ = client.delete("/x", headers=h)
