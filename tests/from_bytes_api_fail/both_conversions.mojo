# Must not compile (M3-041): a body type that conforms to both FromBody and
# FromBytes has two conversions; Muntin picks neither silently, and the
# registration owns the message.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's type conforms to both FromBody and FromBytes; a body type conforms to one of them
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


def upload(body: Either) -> String:
    return String(body.n)


def main():
    var app = App()
    app.post["/upload"](upload)
