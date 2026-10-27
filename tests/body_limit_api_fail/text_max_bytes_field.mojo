# Must not compile (M3-089): FromBody's max_bytes is the trait's member, so a
# body type cannot use the name for a field.
# Expected diagnostic (checked by scripts/check.sh): 'Upload' does not implement all requirements for 'FromBody'
from muntin import App, FromBody


struct Upload(FromBody):
    var max_bytes: Int

    def __init__(out self, max_bytes: Int):
        self.max_bytes = max_bytes

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body.byte_length())


def upload(body: Upload) -> String:
    return String(body.max_bytes)


def main():
    var app = App()
    app.post["/u"](upload)
