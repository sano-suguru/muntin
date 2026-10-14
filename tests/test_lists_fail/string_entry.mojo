# Must fail scripts/check_test_lists.sh (scripts/check.sh runs it on this
# file and is never asked to build it), with:
# Expected error: test_important_case is not listed in _tests()
from std.testing import TestSuite


def test_kept() raises:
    pass


def test_important_case() raises:
    pass


def _tests() -> TestSuite:
    var suite = TestSuite()
    suite.test[test_kept]()
    print("suite.test[test_important_case]()")
    return suite^


def main() raises:
    _tests().run()
