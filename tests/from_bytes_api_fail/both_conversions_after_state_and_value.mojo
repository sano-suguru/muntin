# Must not compile (M3-041): the two-conversion rule holds on every body
# shape, here a stateful put with a route value before the body.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's type conforms to both FromBody and FromBytes; a body type conforms to one of them
from muntin import App, FromBody, FromBytes, State


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


@fieldwise_init
struct Store(Movable):
    var n: Int


def upload(store: State[Store], id: Int, body: Either) -> String:
    return String(id + body.n)


def main():
    var app = App()
    app.put["/upload/{id}"](upload, State(Store(0)))
