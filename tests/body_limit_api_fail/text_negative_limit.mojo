# Must not compile (M3-089): a FromBody type whose max_bytes is
# negative is rejected at registration, as a FromBytes type's (M3-043).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's max_bytes (a Json[T]'s limit) is negative; a body type's max_bytes is a byte count, 0 or more
from muntin import App, FromBody


struct Negative(FromBody):
    comptime max_bytes = -1

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def create(body: Negative) -> String:
    return body.text


def main():
    var app = App()
    app.post["/notes"](create)
