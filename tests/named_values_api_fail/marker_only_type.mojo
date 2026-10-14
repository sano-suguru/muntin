# Must not compile: an application type conformed to the private marker
# _NamedValue directly is no route value; only Param is (exact type
# equality in _named_kind). Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int or String route value, an Optional of one, the request Headers or, for a raw handler, the Request
from muntin import App
from muntin.route_value import _NamedValue


struct Fake(_NamedValue):
    comptime _placeholder = "x"
    comptime _Value = Int
    var value: Int

    def __init__(out self, var value: Int):
        self.value = value

    @staticmethod
    def _wrap(var value: Int) -> Self:
        return Self(value)


def h(x: Fake) -> String:
    return String(x.value)


def main():
    var app = App()
    app.get["/x/{x}"](h)
