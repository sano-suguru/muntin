# Must build, never run (M3-008, candidate 4b rejected): a minimal model of
# blanket result conversion by relaxing a registration overload's bound.
# `R: Movable & Deinitable` with the conformance asserted inside still lets
# a `-> String` handler select the `String` overload (the shorter parameter
# list), but storing the handler needs its function type `rebind`-ed to a
# `downcast` result inside the registrar, and a non-conforming result then
# fails as an instantiation `constraint failed`
# (tests/json_fail/relaxed_result_bound_diagnostic.mojo) instead of
# `no matching method ... does not conform to trait 'ToResponse'`.
from std.builtin.rebind import downcast

from muntin import Response, ToResponse


struct Registrar:
    var kinds: List[String]

    def __init__(out self):
        self.kinds = List[String]()

    def get[
        E: Deinitable, //
    ](mut self, handler: def() thin raises E -> String):
        self.kinds.append("string")

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
        self.kinds.append("converted")


def hello() -> String:
    return "hello"


def health() -> Response:
    return Response.text("ok")


def main():
    var r = Registrar()
    r.get(hello)
    r.get(health)
