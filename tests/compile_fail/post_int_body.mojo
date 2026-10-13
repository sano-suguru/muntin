# Must not compile: a lone Int on a POST route with no placeholder. Int is a
# route value, never the body (M2-005), so the handler is bodyless and takes
# `get`'s rules: its value needs a placeholder (M3-048).
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post,
# put and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.post["/users"](h)
