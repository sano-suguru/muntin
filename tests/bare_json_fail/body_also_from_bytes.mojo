# Expected diagnostic (checked by scripts/check.sh): a parameter's type is a JsonFields struct and conforms to FromBody, FromBytes
from muntin import App, FromBytes, JsonFields


struct In(FromBytes, JsonFields):
    comptime max_bytes = 16
    var size: Int

    def __init__(out self, size: Int):
        self.size = size

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def create(body: In) -> String:
    return String(body.size)


def main():
    var app = App()
    app.post["/x"](create)
