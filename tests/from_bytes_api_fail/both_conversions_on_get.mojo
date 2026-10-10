# Must not compile (M3-041): a type with both conversions is still a body
# where the rules look for one, so get rejects it as a body.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body
from muntin import App, FromBody, FromBytes


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


def show(body: Either) -> String:
    return String(body.n)


def main():
    var app = App()
    app.get["/x"](show)
