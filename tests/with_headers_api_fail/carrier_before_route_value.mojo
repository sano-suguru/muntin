# Must not compile: a carrier before the route value. The carrier is a
# body, and the body is the handler's last parameter, so
# `def(WithHeaders[B], Int)` matches no `post` overload (M3-013;
# docs/ARCHITECTURE.md, "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def update_note(input: WithHeaders[Note], id: Int) thin -> String' to 'def(Int, var B) raises Never thin -> String'

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
