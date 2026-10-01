# Must not compile: with no route value declared, an `Int` parameter would sit
# in the body slot. Builtins are route-value types only, never bodies, so a
# forgotten `{id}` stays a compile error instead of reading the body.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter

from extraction_spike import ExtractApp


def get_item(id: Int) -> String:
    return String(id)


def main():
    var app = ExtractApp()
    app.post["/items"](get_item)
