# Must not compile: on the selected design's model, a handler parameter of
# no slot kind (`Float64`) is reported with the registration rule, not
# with an adapter's failure. The overload's rule check is a Bool that
# guards the adapter's instantiation; without that guard Mojo 1.1.0
# reports the adapter's own failure first and the rule's message never
# appears (docs/ARCHITECTURE.md, "Registration structure decision
# (M3-014)").
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a handler parameter is not a route value (Int, String), a request body (FromBody, WithHeaders), Headers or Request
from registration_spike import Registrar


def bad(x: Float64) -> String:
    return "x"


def main():
    var reg = Registrar()
    reg.on["GET", "/x"](bad)
