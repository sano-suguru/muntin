# Must not compile: the route declares one value and the handler takes two
# `Int`s, so the second would sit in the body slot. Registration rejects a
# route-value type there by type equality, whatever conformances exist.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Int is a route-value type, never the request body; declare a path or query parameter for every Int parameter

from extraction_spike import ExtractApp


def add(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = ExtractApp()
    app.post["/x/{a}"](add)
