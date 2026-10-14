# Must not compile, and pins a Mojo 1.1.0 compiler crash rather than a
# Muntin rule: discovering a module's tests
# (`TestSuite.discover_tests[__functions_in_module()]`) segfaults when a
# function in the module declares a parameter whose type has a string
# parameter, as `Param["id", Int]` does (a bare `struct P[name: StaticString]`
# crashes too; an `Int` parameter does not). Importing such a function does
# not crash, so tests/test_named_values.mojo keeps its handlers in
# tests/named_value_handlers.mojo. When this builds, the crash is fixed: the
# handlers may move back into the test module. Decision:
# docs/history/architecture-decisions.md, "Named route values decision
# (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): Please submit a bug report to https://github.com/modular/modular/issues
from std.testing import TestSuite

from muntin import Param


def get_user(id: Param["id", Int]) -> String:
    return String(id.value)


def test_nothing() raises:
    pass


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
