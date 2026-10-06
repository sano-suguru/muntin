# Must not compile: a carrier before the route value. The carrier is a body, and
# the body is the handler's last parameter, so post's two-slot overload reports
# it (M3-013, M3-015; docs/history/architecture-decisions.md, "Typed header
# access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter

from muntin import App, FromBody, WithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def update_note(input: WithHeaders[Note], id: Int) -> String:
    return input.body.text


def main():
    var app = App()
    app.post["/notes/{id}"](update_note)
