# Must not compile: a placeholder named twice (get). Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the route declares the parameter {id} twice; a RouteValues record binds each parameter to the field of its name
from muntin import App, RouteValues


@fieldwise_init
struct Twice(RouteValues):
    var id: Int
    var other: Int


def h(at: Twice) -> String:
    return ""


def main():
    var app = App()
    app.get["/a/{id}/b/{id}"](h)
