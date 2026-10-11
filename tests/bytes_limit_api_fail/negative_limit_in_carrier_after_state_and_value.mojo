# Must not compile (M3-043): the carrier reads its FromBytes type's
# max_bytes, so a negative one is rejected inside WithHeaders too, here on a
# stateful shape with a route value.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's max_bytes is negative; a FromBytes type's max_bytes is a byte count, 0 or more
from muntin import App, FromBytes, State, WithHeaders


struct Negative(FromBytes):
    comptime max_bytes = -1

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


struct Store(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def upload(
    store: State[Store], id: Int, input: WithHeaders[Negative]
) -> String:
    return String(store[].n, id, input.body.n)


def main():
    var app = App()
    app.patch["/upload/{id}"](upload, State(Store(1)))
