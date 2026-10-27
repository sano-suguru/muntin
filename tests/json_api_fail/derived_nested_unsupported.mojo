# Must not compile (M3-083): a Float32 field of a struct in a List field; the
# message names the innermost field, not the List field that holds it.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field at of the JsonFields struct derived_nested_unsupported.Inner has type SIMD[DType.float32, 1], which cannot be written
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
