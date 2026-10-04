# Must not compile (M3-011): `get`'s header fields are keyword-only, so a
# request that carries fields says `headers=` at the call; a positional
# second argument (fields or a string) is rejected.
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'get': unexpected argument
from muntin import App, Headers
from muntin.testing import TestClient


def main():
    var app = App()
    var client = TestClient(app)
    var h = Headers()
    _ = client.get("/x", h^)
