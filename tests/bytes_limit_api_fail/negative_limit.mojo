# Must not compile (M3-043): a FromBytes type whose max_bytes is negative is
# rejected at registration; a limit is a byte count, 0 or more.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's max_bytes is negative; a FromBytes type's max_bytes is a byte count, 0 or more
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
    app.post["/upload"](upload)
