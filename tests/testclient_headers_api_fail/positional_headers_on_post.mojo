# Must not compile (M3-011): `post`'s header fields are keyword-only, as on
# `get`; a positional third argument is rejected.
# Since M3-040 `post` has a text and a bytes overload, so the compiler reports
# `no matching method in call to 'post'` with each candidate's reason.
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'post'
from muntin import App, Headers
from muntin.testing import TestClient


def main():
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    _ = client.post("/x", "b", h^)
