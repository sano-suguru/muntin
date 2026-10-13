# Must not compile: a bodyless `put` handler's route value needs its
# placeholder, as on `get`.
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post, put
# and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter
from muntin import App


def h(id: Int) -> String:
    return "x"


def main():
    var app = App()
    app.put["/x"](h)
