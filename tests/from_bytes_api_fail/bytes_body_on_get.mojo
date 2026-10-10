# Must not compile (M3-041): get takes no request body, a bytes body included.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body
from muntin import App, FromBytes


struct Payload(FromBytes):
    comptime max_bytes = Int.MAX

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
    app.get["/upload"](upload)
