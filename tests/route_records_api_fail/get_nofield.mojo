# Must not compile: a record with no field (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the RouteValues record has no field; a record has one field per path or query parameter
from muntin import App, RouteValues


struct Empty(RouteValues):
    def __init__(out self):
        pass


def h(at: Empty) -> String:
    return ""


def main():
    var app = App()
    app.get["/x"](h)
