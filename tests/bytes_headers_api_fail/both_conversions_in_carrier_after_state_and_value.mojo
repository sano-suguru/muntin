# Must not compile (M3-042): a carrier around a type with both conversions is rejected on every
# shape, here stateful after a route value: Muntin never picks a conversion
# silently, and the carrier now converts with from_bytes or from_body.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's type conforms to both FromBody and FromBytes; a body type conforms to one of them
from muntin import App, FromBody, FromBytes, State, WithHeaders


struct Either(FromBody, FromBytes):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body.byte_length())

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


struct Store(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def upload(store: State[Store], id: Int, input: WithHeaders[Either]) -> String:
    return String(store[].n, id, input.body.n)


def main():
    var app = App()
    app.patch["/upload/{id}"](upload, State(Store(1)))
