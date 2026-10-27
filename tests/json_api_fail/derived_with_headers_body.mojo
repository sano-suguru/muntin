# Must not compile (M3-083): a derived body carried by `WithHeaders` is
# refused at the registration like a bare one, naming the innermost field.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field at of the JsonFields struct derived_with_headers_body.Inner has type SIMD[DType.float16, 1], which cannot be read
from muntin import App, Json, JsonFields, WithHeaders


@fieldwise_init
struct Inner(Copyable, JsonFields):
    var at: Float16


@fieldwise_init
struct Outer(JsonFields):
    var inner: Optional[Inner]


def h(input: WithHeaders[Json[Outer]]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
