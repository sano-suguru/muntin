# Must not compile: (Int, Int) on a route with one placeholder puts an Int in
# the body slot. Rejected by type equality, whatever conformances exist
# (M2-005, M2-009).
# Expected diagnostic (checked by scripts/check.sh): Int is a route-value type, never the request body; the body parameter's type must conform to FromBody

from muntin import App


def h(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = App()
    app.post["/users/{id}"](h)
