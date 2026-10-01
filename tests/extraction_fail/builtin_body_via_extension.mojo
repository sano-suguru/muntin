# Must not compile on 1.1.0: an application module cannot extend a builtin
# with a trait imported from another module (`Int` is `SIMD`, so the
# extension targets `SIMD`). The same extension in the trait's own module
# does give `Int` the trait bound (extension_invisible_to_conforms_to.mojo).
# If this starts failing with Muntin's "Int is a route-value type" message
# instead, cross-module extensions work: an application could then make a
# builtin a body type, and only the registration's type-equality check keeps
# a forgotten `{b}` from reading the body (docs/ARCHITECTURE.md, "Argument
# extraction decision", revisit conditions).
# Expected diagnostic (checked by scripts/check.sh): does not implement all requirements for 'FromBody'

from extraction_spike import ExtractApp, FromBody


__extension SIMD(FromBody):
    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(0)


def add(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = ExtractApp()
    app.post["/x/{a}"](add)
