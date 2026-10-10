# Must not compile: `TestClient.patch`'s header fields are keyword-only, as on
# `get` and `post` (M3-011); a positional `Headers` is rejected. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Since M3-040 `patch` has a text and a bytes overload, so the compiler reports
# `no matching method in call to 'patch'` with each candidate's reason.
# Expected diagnostic (checked by scripts/check.sh): candidate not viable: unexpected argument
from muntin import App, Headers
from muntin.testing import TestClient


def main():
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    _ = client.patch("/x", "b", h^)
