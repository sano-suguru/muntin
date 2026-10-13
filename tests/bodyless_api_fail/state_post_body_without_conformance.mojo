# Must not compile: a stateful `post` handler whose last parameter has no kind
# gets the body message, not a bodyless one.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's last parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App, State


struct Form(Movable):
    var name: String


@fieldwise_init
struct Db(Movable):
    var name: String


def h(db: State[Db], form: Form) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](h, State(Db("d")))
