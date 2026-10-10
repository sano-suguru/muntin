# Built by scripts/check.sh with only tests/json_spike.mojo beside it: the
# codec and `Json[T]` must convert application types the library side has
# never seen (M3-008).
from muntin import Headers, Request
from json_spike import (
    FromJson,
    Json,
    JsonValue,
    JsonWriter,
    ToJson,
    model_post,
)


@fieldwise_init
struct Point(FromJson, ToJson):
    var x: Int
    var label: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["x"].int(), value["label"].string())

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("x")
        out.int(self.x + 1)
        out.name("label")
        out.string(self.label)
        out.end_object()


def bump(body: Json[Point]) -> Json[Point]:
    return Json(Point(body.value.x, body.value.label))


def main() raises:
    var h = Headers()
    h.add("Content-Type", "application/json")
    var r = model_post(
        bump, Request("POST", "/p", '{"x":1,"label":"a\\"b"}', h^)
    )
    if r.status != 200 or r.text() != '{"x":2,"label":"a\\"b"}':
        raise Error("round trip failed: " + String(r.status) + " " + r.text())
    if r.headers.get("content-type").value() != "application/json":
        raise Error("missing Content-Type")
    if model_post(bump, Request("POST", "/p", '{"x":1}')).status != 415:
        raise Error("missing Content-Type was not 415")
    print("ok")
