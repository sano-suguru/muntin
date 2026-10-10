# Must not compile (M3-042): generic code bounded by FromBytes does not accept the
# carrier: it is a body-slot type, not a conversion.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): 'convert' parameter 'B' has 'FromBytes' type, but value has type 'AnyStruct[WithHeaders[Blob]]'
from muntin import FromBytes, WithHeaders


struct Blob(FromBytes):
    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def convert[B: FromBytes](body: List[UInt8]) raises -> B:
    return B.from_bytes(body)


def main() raises:
    var bytes: List[UInt8] = [0xFF]
    _ = convert[WithHeaders[Blob]](bytes)
