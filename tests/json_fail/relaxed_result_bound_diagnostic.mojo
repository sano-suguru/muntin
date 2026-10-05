# Must not compile (M3-008, candidate 4b): with the relaxed bound of
# tests/json_known_gaps/relaxed_result_bound.mojo, an `Int` result reaches
# the generic overload and fails inside it ("function instantiation failed"
# with the assert's text), where production rejects it during overload
# resolution: its trait bound did until M3-015 (`does not conform to trait
# 'ToResponse'`), its `where` clause does since
# (tests/storage_fail/non_conforming_return_handler.mojo and 5 more).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: result must conform to ToResponse or ToJson
from std.builtin.rebind import downcast

from muntin import ToResponse


struct Registrar:
    def __init__(out self):
        pass

    def get[
        E: Deinitable, //
    ](mut self, handler: def() thin raises E -> String):
        pass

    def get[
        E: Deinitable, R: Movable & Deinitable, //
    ](mut self, handler: def() thin raises E -> R):
        comptime assert conforms_to(
            R, ToResponse
        ), "result must conform to ToResponse or ToJson"
        var stored = rebind[def() thin raises E -> downcast[R, ToResponse]](
            handler
        )
        _ = stored


def count() -> Int:
    return 1


def main():
    var r = Registrar()
    r.get(count)
