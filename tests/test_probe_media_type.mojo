# Probe for M3-094 (pull request #207), removed before merge: the media type
# named by a type parameter (a struct whose `comptime name` is the text)
# instead of a string parameter, with a compile-time check of the text, under
# `TestSuite.discover_tests`.
from std.testing import assert_equal, TestSuite


trait JsonMedia:
    comptime name: StaticString


struct ApplicationJson(JsonMedia):
    comptime name: StaticString = "application/json"


struct MergePatch(JsonMedia):
    comptime name: StaticString = "application/merge-patch+json"


def _media_ok(name: StaticString) -> Bool:
    var s = String(name)
    if s == "application/json":
        return True
    return (
        s.startswith("application/")
        and s.endswith("+json")
        and len(s) > len("application/+json")
    )


struct Body[
    T: Movable & Deinitable, *, limit: Int = 8, M: JsonMedia = ApplicationJson
](Movable):
    var value: Self.T

    def __init__(out self, var value: Self.T):
        self.value = value^

    @staticmethod
    def media_type() -> String:
        comptime assert _media_ok(Self.M.name), "not a JSON media type"
        return String(Self.M.name)


def handler(body: Body[Int, M=MergePatch]) -> Body[Int]:
    return Body[Int](body.value + 1)


def test_type_media() raises:
    assert_equal(Body[Int].media_type(), "application/json")
    assert_equal(
        Body[Int, M=MergePatch].media_type(), "application/merge-patch+json"
    )
    assert_equal(handler(Body[Int, M=MergePatch](1)).value, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
