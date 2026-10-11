# Must not compile (M3-042): a delete handler takes no body; a carrier is a body, whatever it carries.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a delete handler takes no request body
from muntin import App, FromBytes, WithHeaders


struct Blob(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(id: Int, input: WithHeaders[Blob]) -> String:
    return String(id, len(input.body.data))


def main():
    var app = App()
    app.delete["/upload/{id}"](upload)
