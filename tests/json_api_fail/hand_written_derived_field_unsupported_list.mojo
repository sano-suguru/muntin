# Must not compile (M3-087 prototype): out.field of a List no derived field takes: the generic overload
# matches the Iterable and its assert names the type (a non-Iterable one is
# still no matching method: field_without_to_json).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: List[SIMD[DType.uint8, 1]] cannot be written: a derived value is
from muntin import App, Json, JsonWriter, ToJson


@fieldwise_init
struct Bytes(ToJson):
    var b: List[UInt8]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("b", self.b)
        out.end_object()


def h() -> Json[Bytes]:
    return Json(Bytes([1]))


def main():
    var app = App()
    app.get["/c"](h)
