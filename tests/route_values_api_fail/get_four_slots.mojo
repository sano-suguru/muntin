# Must not compile: four request parameters match none of `get`'s eight
# overloads (the largest slot arity is 3), so the compiler's own diagnostic
# names the method. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'get'
from muntin import App, Headers


def h(a: Int, b: Int, c: Int, headers: Headers) -> String:
    return String(a + b + c)


def main():
    var app = App()
    app.get["/x/{a}/{b}/{c}"](h)
