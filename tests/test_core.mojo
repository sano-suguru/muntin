from std.testing import assert_equal, TestSuite

from muntin import greet


def test_greet() raises:
    assert_equal(greet("Muntin"), "Hello, Muntin!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
