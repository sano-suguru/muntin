# Must not compile (M3-082 prototype): a Float32 field of a struct in a List field (the slice names the innermost field).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field inner of the JsonFields struct derived_nested_unsupported.Outer has type List[derived_nested_unsupported.Inner], which cannot be written
from muntin import App, Json, JsonFields


@fieldwise_init
struct Inner(Copyable, JsonFields):
    var at: Float32


@fieldwise_init
struct Outer(JsonFields):
    var inner: List[Inner]


def h() -> Json[Outer]:
    return Json(Outer([]))


def main():
    var app = App()
    app.get["/c"](h)
