# Must not compile, and pins a Mojo 1.1.0 compiler crash rather than a
# Muntin rule: discovering a module's tests
# (`TestSuite.discover_tests[__functions_in_module()]`) segfaults when a
# function in the module declares a parameter whose type has a string
# parameter, as `Param["id", Int]` does (a bare `struct P[name: StaticString]`
# crashes too; an `Int` parameter does not). A module that defines Param
# handlers registers its tests by hand, or keeps the handlers in another
# module. When this builds, the crash is fixed: drop the workaround in the
# test modules that list their tests by hand. Decision:
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
