# Must not compile (M3-041): a bytes body is the last parameter, as any body.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a patch handler takes one request body, as its last parameter
from muntin import App, FromBytes


struct Payload(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def update(body: Payload, id: Int) -> String:
    return String(id, len(body.data))


def main():
    var app = App()
    app.patch["/items/{id}"](update)
