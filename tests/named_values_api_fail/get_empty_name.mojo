# Must not compile: a Param with an empty name is a Param, checked like any
# other; no placeholder name is empty. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 1 is Param[""] but binds {id}; route values bind the path parameters left to right, then the query parameters
from muntin import App, Param


def h(id: Param["", Int]) -> String:
    return String(id.value)


def main():
    var app = App()
    app.get["/x/{id}"](h)
