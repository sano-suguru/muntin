# Must not compile (M3-041): a type with a from_bytes method that does not
# declare FromBytes is not a body; conformance is declared, never inferred.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App


struct Payload(Movable):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(body: Payload) -> String:
    return String(len(body.data))


def main():
    var app = App()
    app.post["/upload"](upload)
