# Must not compile: one named value whose name has a typo. One value may be
# plain, but a Param is always checked. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 1 is Param["idd"] but binds {id}; route values bind the path parameters left to right, then the query parameters
from muntin import App, Param


def get_user(id: Param["idd", Int]) -> String:
    return String(id.value)


def main():
    var app = App()
    app.get["/users/{id}"](get_user)
