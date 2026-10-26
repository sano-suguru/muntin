# M3-091 prototype: the spike's `Param` handler, in its own module so that
# tests/test_spike_openapi.mojo can discover its tests (as
# tests/named_value_handlers.mojo for tests/test_named_values.mojo).

from muntin import Param


def delete_note(id: Param["id", Int]) -> String:
    return "deleted"
