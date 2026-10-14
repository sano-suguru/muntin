# Must not compile: two route values with no names. Two values of one type
# could be declared in either order, so both must be Params. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes two route values; each is a Param named after the placeholder it binds, as Param["name", Int]
from muntin import App


def post_of(uid: Int, pid: Int) -> String:
    return String("post ", pid, " of user ", uid)


def main():
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
