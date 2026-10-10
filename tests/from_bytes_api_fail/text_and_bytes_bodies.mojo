# Must not compile (M3-041): a handler takes one request body, never a text
# body and a bytes body of the same request.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter
from muntin import App, FromBody, FromBytes


struct Payload(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def upload(note: Note, body: Payload) -> String:
    return note.text + String(len(body.data))


def main():
    var app = App()
    app.post["/upload"](upload)
