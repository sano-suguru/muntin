# Must not compile (M3-040): `FromBody.from_body` and `Json[T].from_body` take
# text; a raw handler passes `req.text()` (strict UTF-8), never the bytes, so
# no conversion can read a body without that check.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'body' cannot be converted from 'List[UInt8]' to 'String'
from muntin import FromJson, Json, JsonValue, Request, Response


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


def greet(req: Request) raises -> Response:
    return Response.text(Json[Name].from_body(req.body).value.name)


def main():
    _ = greet
