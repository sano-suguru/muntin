# Probe for M3-094 (pull request #207), removed before merge: does a test
# module whose functions take a struct with a defaulted, keyword-only
# `StaticString` parameter, written only at its default, survive
# `TestSuite.discover_tests` (tests/named_values_api_fail/discover_tests_crash.mojo)?
from std.testing import assert_equal, TestSuite


struct Body[T: Movable & Deinitable, *, limit: Int = 8, media: StaticString = "application/json"](Movable):
    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^

    @staticmethod
    def media_type() -> String:
        return String(Self.media)


def handler(body: Body[Int]) -> Body[Int]:
    return Body[Int](body.value + 1)


def test_default_media() raises:
    assert_equal(Body[Int].media_type(), "application/json")
    assert_equal(handler(Body[Int](1)).value, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
