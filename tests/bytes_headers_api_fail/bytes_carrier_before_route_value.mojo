# Must not compile (M3-042): the body, a bytes carrier included, is the last parameter.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a put handler takes one request body, as its last parameter
from muntin import App, FromBytes, WithHeaders


struct Blob(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(input: WithHeaders[Blob], id: Int) -> String:
    return String(id, len(input.body.data))


def main():
    var app = App()
    app.put["/upload/{id}"](upload)
