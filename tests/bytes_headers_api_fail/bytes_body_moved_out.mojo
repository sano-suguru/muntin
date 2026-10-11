# Must not compile (M3-042): moving the bytes body field out of a carrier. Mojo 1.1.0
# does not move a field out of the middle of a value; `take_body(deinit self)`
# moves the body out.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): field 'input.body.data' destroyed out of the middle of a value
from muntin import FromBytes, WithHeaders


struct Blob(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def upload(var input: WithHeaders[Blob]) -> String:
    var b = input.body^
    return String(len(b.data))


def main():
    pass
