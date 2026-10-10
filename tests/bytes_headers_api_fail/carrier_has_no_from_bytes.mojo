# Must not compile (M3-042): the carrier is not itself a FromBytes, so a body's bytes
# alone cannot produce a carrier without the request's fields.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders[Blob]' value has no attribute 'from_bytes'
from muntin import FromBytes, WithHeaders


struct Blob(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def main() raises:
    var bytes: List[UInt8] = [0xFF]
    _ = WithHeaders[Blob].from_bytes(bytes)
