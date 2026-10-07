# Must not compile: a handler parameter of no slot kind (`Float64`) is reported
# with the registration rule, not with an adapter's failure. The overload's rule
# check is a Bool that guards the adapter's instantiation; without that guard
# Mojo 1.1.0 reports the adapter's own failure first and the rule's message
# never appears (docs/history/architecture-decisions.md, "Registration structure
# decision (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request
from muntin import App


def bad(x: Float64) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x"](bad)
