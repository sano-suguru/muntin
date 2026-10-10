# Must not compile (M3-043): a FromBytes type with a negative max_bytes
# before a route value is still a body out of place.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a put handler takes one request body, as its last parameter
from muntin import App, FromBytes


struct Negative(FromBytes):
    comptime max_bytes = -1

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def upload(body: Negative, id: Int) -> String:
    return String(body.n, id)


def main():
    var app = App()
    app.put["/upload/{id}"](upload)
