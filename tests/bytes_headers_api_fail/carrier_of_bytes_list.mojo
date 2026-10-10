# Must not compile (M3-042): `List[UInt8]` is the raw body representation, not a
# conversion: the carrier's body must conform to FromBody or FromBytes,
# checked where the handler is declared.
# docs/history/architecture-decisions.md, "Typed binary request bodies with
# header fields decision (M3-042)".
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has '_FromBodyOrBytes' type, but value has type 'AnyStruct[List[UInt8]]'
from muntin import WithHeaders


def upload(input: WithHeaders[List[UInt8]]) -> String:
    return String(len(input.body))


def main():
    pass
