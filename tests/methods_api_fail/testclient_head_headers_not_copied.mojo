# Must not compile: `TestClient.head` takes the header fields by move, as on
# `get` and the other methods (M3-010), so a plain variable is not copied
# silently. Decision: docs/history/architecture-decisions.md, "TestClient
# HEAD decision (M3-036)".
# Expected diagnostic (checked by scripts/check.sh): cannot be implicitly copied
from muntin import App, Headers
from muntin.testing import TestClient


def main() raises:
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-A", "1")
    _ = client.head("/x", headers=h)
