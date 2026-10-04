# Must not compile (M3-009): the production parsed tape is held in M3-004's
# sealed `_Shared` box, so a second `JsonValue` cannot clear or replace the
# document another position indexes. `_parse_json` and `_doc` are internal;
# they are named here only to reach a second handle.
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'clear': invalid use of mutating method on rvalue of type 'List[_Node]'
from muntin.json import _parse_json


def main() raises:
    var v = _parse_json('{"a":1}')
    var v2 = v.copy()
    v2._doc.owned()[].nodes.clear()
    _ = v["a"].int()
