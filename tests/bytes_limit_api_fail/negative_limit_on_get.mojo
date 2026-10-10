# Must not compile (M3-043): a FromBytes type with a negative max_bytes is
# still a body for the other rules, so get reports that it takes none.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body
from muntin import App, FromBytes


struct Negative(FromBytes):
    comptime max_bytes = -1

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def upload(body: Negative) -> String:
    return String(body.n)


def main():
    var app = App()
    app.get["/upload"](upload)
