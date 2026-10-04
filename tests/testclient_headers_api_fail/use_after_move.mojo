# Must not compile (M3-011): `headers=h^` moves the fields into the request;
# the variable cannot be used afterwards (pass `h.copy()` to keep it).
# Expected diagnostic (checked by scripts/check.sh): use of uninitialized value 'h'
from muntin import App, Headers
from muntin.testing import TestClient


def main() raises:
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    h.add("X-A", "1")
    _ = client.get("/x", headers=h^)
    print(len(h))
