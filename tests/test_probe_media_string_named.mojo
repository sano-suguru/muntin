# Probe for M3-094 (pull request #207), removed before merge: as
# test_probe_media_string_default.mojo, with the parameter written.
from std.testing import assert_equal, TestSuite


struct Body[T: Movable & Deinitable, *, limit: Int = 8, media: StaticString = "application/json"](Movable):
    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^

    @staticmethod
    def media_type() -> String:
        return String(Self.media)


def handler(
    body: Body[Int, media="application/merge-patch+json"]
) -> Body[Int]:
    return Body[Int](body.value + 1)


def test_named_media() raises:
    assert_equal(
        Body[Int, media="application/merge-patch+json"].media_type(),
        "application/merge-patch+json",
    )
    assert_equal(
        handler(Body[Int, media="application/merge-patch+json"](1)).value, 2
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
