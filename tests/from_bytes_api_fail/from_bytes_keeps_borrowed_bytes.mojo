# Must not compile (M3-041): from_bytes borrows the request's body bytes; a
# value that keeps them copies them (body.copy()), so a converted value never
# aliases Request.body.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): value of type 'List[UInt8]' cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'
from muntin import FromBytes


struct Payload(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body)


def main():
    pass
