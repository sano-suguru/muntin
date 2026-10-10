# Must not compile (M3-042): a get handler takes no body; a carrier is a body, whatever it carries.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body
from muntin import App, FromBytes, WithHeaders


struct Blob(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(input: WithHeaders[Blob]) -> String:
    return String(len(input.body.data))


def main():
    var app = App()
    app.get["/upload"](upload)
