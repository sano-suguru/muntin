# Must not compile (M3-043): max_bytes is an Int; a type that declares it as
# another type does not conform to FromBytes.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): comptime member 'max_bytes' type 'UInt' does not conform to trait's required type 'Int'
from muntin import FromBytes


struct Unsigned(FromBytes):
    comptime max_bytes: UInt = 1024

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def main():
    print(Unsigned.max_bytes)
