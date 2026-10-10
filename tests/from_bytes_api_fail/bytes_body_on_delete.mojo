# Must not compile (M3-041): delete takes get's shapes, so no request body, a
# bytes body included (a raw handler reads a DELETE body).
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes no request body
from muntin import App, FromBytes


struct Payload(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def remove(id: Int, body: Payload) -> String:
    return String(id, len(body.data))


def main():
    var app = App()
    app.delete["/items/{id}"](remove)
