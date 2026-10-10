# Must not compile (M3-041): a carrier converts its body as a bare body of its
# type does (from_body or, since M3-042, from_bytes), so a carrier around a
# type with both conversions would pick one silently; it is rejected as the
# type alone is.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's type conforms to both FromBody and FromBytes; a body type conforms to one of them
from muntin import App, FromBody, FromBytes, WithHeaders


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


def upload(input: WithHeaders[Either]) -> String:
    return String(input.body.n)


def main():
    var app = App()
    app.post["/upload"](upload)
