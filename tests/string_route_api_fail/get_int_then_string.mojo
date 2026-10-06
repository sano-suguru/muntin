# Must not compile: a get handler takes at most one route value, whatever its
# type; with a `String` among two the message drops `Int`, and `def(Int, Int)`
# keeps "at most one Int route value" (tests/storage_fail/two_param_handler.mojo).
# The rule fires before the placeholder count, so two placeholders do not help.
# Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes at most one route value
from muntin import App


def h(id: Int, name: String) -> String:
    return name


def main():
    var app = App()
    app.get["/x/{a}/{b}"](h)
