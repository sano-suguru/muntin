# Must not compile (M3-041): from_bytes borrows the bytes; a conversion that
# declares them owned (var) does not implement FromBytes, so Muntin never
# copies a body to hand it over.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): 'Payload' does not implement all requirements for 'FromBytes'
from muntin import FromBytes


struct Payload(FromBytes):
    comptime max_bytes = Int.MAX

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(var body: List[UInt8]) raises -> Self:
        return Self(body^)


def main():
    pass
