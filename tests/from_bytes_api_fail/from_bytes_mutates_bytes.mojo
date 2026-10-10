# Must not compile (M3-041): the bytes from_bytes receives are read-only; a
# conversion cannot change the request's body.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): invalid use of mutating method on rvalue of type 'List[UInt8]'
from muntin import FromBytes


struct Payload(FromBytes):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        body.append(0)
        return Self(len(body))


def main():
    pass
