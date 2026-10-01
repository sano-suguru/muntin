# Must not compile: with no route value declared, a lone `Int` parameter
# would sit in the body slot. It resolves to the non-generic `def(Int)`
# overload (observed 1.1.0 preference over the generic `def(var B)` one) and
# fails its arity check, so a forgotten `{id}` stays a compile error. The
# two-`Int` case that does reach the body overload is
# two_ints_one_route_value.mojo.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Int parameter; route must declare exactly one path or query parameter

from extraction_spike import ExtractApp


def get_item(id: Int) -> String:
    return String(id)


def main():
    var app = ExtractApp()
    app.post["/items"](get_item)
