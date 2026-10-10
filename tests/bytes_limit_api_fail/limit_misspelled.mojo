# Must not compile (M3-043): every FromBytes type states its limit, so a type
# that misspells max_bytes (max_byte) does not conform: a forgotten limit
# fails at the declaration instead of leaving the body unlimited.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): required member 'max_bytes' is not specified
from muntin import App, FromBytes


struct Upload(FromBytes):
    comptime max_byte = 4096
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def upload(body: Upload) -> String:
    return String(body.n)


def main():
    var app = App()
    app.post["/upload"](upload)
