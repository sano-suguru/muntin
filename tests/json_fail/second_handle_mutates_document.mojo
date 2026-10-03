# Must not compile (M3-008): the parsed tape is held in M3-004's sealed
# `_Shared` box, so a second `JsonValue` cannot clear or replace the
# document another position indexes (with `ArcPointer`, `v2._doc[].clear()`
# would compile and leave `v`'s position dangling).
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'clear': invalid use of mutating method on rvalue of type 'List[_Node]'
from json_spike import parse_json


def main() raises:
    var v = parse_json('{"a":1}')
    var v2 = v.copy()
    v2._doc.owned()[].clear()
    _ = v["a"].int()
