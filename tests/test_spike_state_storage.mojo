# M3-004 state-storage decision spike, application side. State types live
# here; the library side (tests/state_storage_spike.mojo) never names them.
# Decision and evidence: docs/ARCHITECTURE.md, "State storage decision
# (M3-004)".

from std.memory import ArcPointer
from std.testing import assert_equal, assert_true, TestSuite

from state_storage_spike import State, _Shared, box_handler


struct Tracked(Movable):
    """Records its own destruction in a shared counter held by the test."""

    var n: Int
    var drops: ArcPointer[Int]

    def __init__(out self, n: Int, drops: ArcPointer[Int]):
        self.n = n
        self.drops = drops.copy()

    def __deinit__(deinit self):
        self.drops[] += 1


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^


def _users() -> State[Users]:
    var names = List[String]()
    names.append("ada")
    names.append("bob")
    return State(Users(names^))


def _count[S: Movable & Deinitable](state: State[S]) -> Int:
    return Int(state._shared.count())


def first_name(users: State[Users]) -> String:
    return users[].names[0]


def handles(users: State[Users]) -> String:
    return String(users._shared.count())


def test_copies_share_one_value_and_count() raises:
    var a = _users()
    assert_equal(_count(a), 1)
    var b = a.copy()
    var c = b.copy()
    assert_equal(_count(a), 3)
    assert_equal(b[].names[1], "bob")
    assert_true(a[].names[0] == c[].names[0])
    _ = c^
    assert_equal(_count(a), 2)
    _ = b^
    assert_equal(_count(a), 1)


def test_value_dropped_once_after_the_last_handle() raises:
    var drops = ArcPointer(0)
    var a = State(Tracked(1, drops))
    var b = a.copy()
    _ = a^
    assert_equal(drops[], 0)
    var moved = b^
    assert_equal(moved[].n, 1)
    assert_equal(drops[], 0)
    _ = moved^
    assert_equal(drops[], 1)


def test_repointing_another_handle_keeps_the_value() raises:
    # Assigning a new box to another handle only drops that handle's share;
    # a reference from the first handle still reads the original value.
    var drops = ArcPointer(0)
    var a = State(Tracked(1, drops))
    var b = a.copy()
    ref r = a[]
    b._shared = _Shared(Tracked(2, drops))
    assert_equal(drops[], 0)
    assert_equal(_count(a), 1)
    assert_equal(r.n, 1)
    assert_equal(b[].n, 2)


def test_reassigning_a_handle_releases_its_share() raises:
    var drops = ArcPointer(0)
    var a = State(Tracked(1, drops))
    var b = a.copy()
    assert_equal(_count(b), 2)
    b = State(Tracked(2, drops))
    assert_equal(drops[], 0)
    assert_equal(_count(a), 1)
    a = State(Tracked(3, drops))
    assert_equal(drops[], 1)
    assert_equal(a[].n, 3)
    assert_equal(b[].n, 2)


def test_requests_borrow_the_boxed_handle() raises:
    # One copy per registration, stored in production `_Erased`; invoking
    # it borrows that copy, so the count is the same inside the handler,
    # across calls and between them, and falls when the box is dropped.
    var users = _users()
    var counted = box_handler(handles, users)
    var named = box_handler(first_name, users)
    assert_equal(_count(users), 3)
    for _ in range(5):
        assert_equal(counted.invoke(List[String]()).body, "3")
        assert_equal(named.invoke(List[String]()).body, "ada")
        assert_equal(_count(users), 3)
    _ = counted^
    _ = named^
    assert_equal(_count(users), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
