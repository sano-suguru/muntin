# Must not compile: two route values, only the first a Param. Of two values,
# both or neither are Params, so how much is checked is plain from the
# handler.
# Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values and only one is a Param; declare both as Param, each named after the placeholder it binds, or neither
from muntin import App, Param


def post_of(uid: Param["uid", Int], pid: Int) -> String:
    return String("post ", pid, " of user ", uid.value)


def main():
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
