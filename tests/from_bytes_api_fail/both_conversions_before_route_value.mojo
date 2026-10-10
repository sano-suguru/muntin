# Must not compile (M3-041): a type with both conversions before a route value
# is a body that is not last, not a route value.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter
from muntin import App, FromBody, FromBytes


struct Either(FromBody, FromBytes):
    comptime max_bytes = Int.MAX

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body.byte_length())

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def update(body: Either, id: Int) -> String:
    return String(id + body.n)


def main():
    var app = App()
    app.post["/x/{id}"](update)
