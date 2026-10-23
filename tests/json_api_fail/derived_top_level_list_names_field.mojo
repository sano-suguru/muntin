# Must not compile (M3-083): a top-level `List` of a struct with an
# unsupported field names that field, not `Json[List[...]]`.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field at of the JsonFields struct derived_top_level_list_names_field.Stamp has type SIMD[DType.int64, 1], which cannot be written
from muntin import App, Json, JsonFields


@fieldwise_init
struct Stamp(Copyable, JsonFields):
    var at: Int64


def h() -> Json[List[Stamp]]:
    return Json(List[Stamp]())


def main():
    var app = App()
    app.get["/c"](h)
