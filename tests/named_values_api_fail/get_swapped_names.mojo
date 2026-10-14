# Must not compile: two values declared in the other order than the
# literal's placeholders. Under positional binding alone they compiled and
# received each other's values (M3-022's accepted cost); a Param's name is
# compared with the placeholder at its position. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 1 is Param["pid"] but binds {uid}; route values bind the path parameters left to right, then the query parameters
from muntin import App, Param


def post_of(pid: Param["pid", Int], uid: Param["uid", Int]) -> String:
    return String("post ", pid.value, " of user ", uid.value)


def main():
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
