# Must not compile (M3-008): a field cannot be moved out of the middle of a
# `Json` on Mojo 1.1.0, so the wrapper offers `take(deinit self)`
# (`body^.take()`).
# Expected diagnostic (checked by scripts/check.sh): field 'body.value.secret' destroyed out of the middle of a value, preventing the overall value from being destroyed
from json_spike import FromJson, Json, JsonValue


struct Token(FromJson):
    var secret: String

    def __init__(out self, var secret: String):
        self.secret = secret^

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["secret"].string())


def keep(var body: Json[Token]) -> Token:
    return body.value^


def main():
    _ = keep(Json(Token("s")))
