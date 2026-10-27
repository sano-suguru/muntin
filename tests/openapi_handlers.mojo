# The `Param` handlers of tests/test_openapi.mojo, in their own module: on
# Mojo 1.1.0 a module whose `__functions_in_module()` holds a function
# taking a `Param` crashes the compiler (as tests/named_value_handlers.mojo
# avoids for tests/test_named_values.mojo).

from muntin import Param


def delete_note(id: Param["id", Int]) -> String:
    return "deleted"


def named_pair(org: Param["org", Int], slug: Param["slug", String]) -> String:
    return "pair"
