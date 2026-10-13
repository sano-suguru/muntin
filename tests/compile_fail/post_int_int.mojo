# Must not compile: (Int, Int) on a route with one placeholder. Int is never
# the body (M2-005, M2-009), so the handler is bodyless with two route values
# and `get`'s two-value placeholder rule applies (M3-048).
# Expected diagnostic (checked by scripts/check.sh): handler takes two route values; route must declare exactly two path or query parameters

from muntin import App


def h(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = App()
    app.post["/users/{id}"](h)
