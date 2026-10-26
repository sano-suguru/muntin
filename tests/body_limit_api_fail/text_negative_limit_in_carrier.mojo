# Must not compile (M3-089): a negative FromBody limit inside
# WithHeaders[B] is rejected at registration, as a bare one.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the request body's max_bytes is negative; a body type's max_bytes is a byte count, 0 or more
from muntin import App, FromBody, WithHeaders


struct Negative(FromBody):
    comptime max_bytes = -1

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def create(id: Int, input: WithHeaders[Negative]) -> String:
    return input.body.text


def main():
    var app = App()
    app.put["/notes/{id}"](create)
