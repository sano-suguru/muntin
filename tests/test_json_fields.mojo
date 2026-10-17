# `JsonWriter.field(name, value)` and the `value(value)` overloads chosen by
# the value's type (M3-075): Int, Float64, Bool, String, a `ToJson` type, and
# an `Optional` (empty: null) or a `List` (an array) of one of those. Decision:
# docs/history/architecture-decisions.md, "JSON writer members decision
# (M3-075)". The writer's structure rules and escapes: tests/test_json.mojo.
# Must-not-compile cases: tests/json_api_fail/field_*.mojo and
# tests/json_api_fail/generic_writer_forwarding.mojo.

from std.collections import Optional
from std.testing import assert_equal, assert_true, TestSuite

from muntin import Json, JsonWriter, ToJson


@fieldwise_init
struct Address(Copyable, ToJson):
    var city: String
    var zip: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("city", self.city)
        out.field("zip", self.zip)
        out.end_object()


struct Token(Movable, ToJson):
    """Move-only: `Optional[Token]` and `List[Token]` are written too."""

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    def write_json(self, mut out: JsonWriter) raises:
        out.string(self.text)


@fieldwise_init
struct Profile(Copyable):
    var id: Int
    var name: String
    var admin: Bool
    var score: Float64
    var nickname: Optional[String]
    var age: Optional[Int]
    var ratio: Optional[Float64]
    var active: Optional[Bool]
    var home: Address
    var work: Optional[Address]
    var tags: List[String]
    var ids: List[Int]
    var scores: List[Float64]
    var flags: List[Bool]
    var past: List[Address]


@fieldwise_init
struct ByField(ToJson):
    var p: Profile

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("id", self.p.id)
        out.field("name", self.p.name)
        out.field("admin", self.p.admin)
        out.field("score", self.p.score)
        out.field("nickname", self.p.nickname)
        out.field("age", self.p.age)
        out.field("ratio", self.p.ratio)
        out.field("active", self.p.active)
        out.field("home", self.p.home)
        out.field("work", self.p.work)
        out.field("tags", self.p.tags)
        out.field("ids", self.p.ids)
        out.field("scores", self.p.scores)
        out.field("flags", self.p.flags)
        out.field("past", self.p.past)
        out.end_object()


@fieldwise_init
struct ByHand(ToJson):
    """The same members through the explicit writer calls."""

    var p: Profile

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.p.id)
        out.name("name")
        out.string(self.p.name)
        out.name("admin")
        out.bool(self.p.admin)
        out.name("score")
        out.float(self.p.score)
        out.name("nickname")
        if self.p.nickname:
            out.string(self.p.nickname.value())
        else:
            out.null()
        out.name("age")
        if self.p.age:
            out.int(self.p.age.value())
        else:
            out.null()
        out.name("ratio")
        if self.p.ratio:
            out.float(self.p.ratio.value())
        else:
            out.null()
        out.name("active")
        if self.p.active:
            out.bool(self.p.active.value())
        else:
            out.null()
        out.name("home")
        self.p.home.write_json(out)
        out.name("work")
        if self.p.work:
            self.p.work.value().write_json(out)
        else:
            out.null()
        out.name("tags")
        out.begin_array()
        for t in self.p.tags:
            out.string(t)
        out.end_array()
        out.name("ids")
        out.begin_array()
        for i in self.p.ids:
            out.int(i)
        out.end_array()
        out.name("scores")
        out.begin_array()
        for s in self.p.scores:
            out.float(s)
        out.end_array()
        out.name("flags")
        out.begin_array()
        for f in self.p.flags:
            out.bool(f)
        out.end_array()
        out.name("past")
        out.begin_array()
        for a in self.p.past:
            a.write_json(out)
        out.end_array()
        out.end_object()


def _text[T: ToJson](value: T) raises -> String:
    var out = JsonWriter()
    value.write_json(out)
    return out^._finish()


def _full() -> Profile:
    return Profile(
        7,
        'A"da\n',
        True,
        -1.5,
        Optional[String]("Al"),
        Optional[Int](36),
        Optional[Float64](0.25),
        Optional[Bool](False),
        Address("X", 1),
        Optional[Address](Address("W", 2)),
        ["a", "b\t"],
        [1, -2],
        [0.5],
        [True, False],
        [Address("Y", 3), Address("Z", 4)],
    )


def _empty() -> Profile:
    return Profile(
        0,
        "",
        False,
        0.0,
        Optional[String](),
        Optional[Int](),
        Optional[Float64](),
        Optional[Bool](),
        Address("", 0),
        Optional[Address](),
        List[String](),
        List[Int](),
        List[Float64](),
        List[Bool](),
        List[Address](),
    )


def test_field_writes_what_the_explicit_calls_write() raises:
    assert_equal(
        _text(ByField(_full())),
        '{"id":7,"name":"A\\"da\\n","admin":true,"score":-1.5,'
        + '"nickname":"Al","age":36,"ratio":0.25,"active":false,'
        + '"home":{"city":"X","zip":1},"work":{"city":"W","zip":2},'
        + '"tags":["a","b\\t"],"ids":[1,-2],"scores":[0.5],'
        + '"flags":[true,false],'
        + '"past":[{"city":"Y","zip":3},{"city":"Z","zip":4}]}',
    )
    assert_equal(_text(ByField(_full())), _text(ByHand(_full())))


def test_empty_optionals_are_null_and_empty_lists_are_arrays() raises:
    assert_equal(
        _text(ByField(_empty())),
        '{"id":0,"name":"","admin":false,"score":0.0,"nickname":null,'
        + '"age":null,"ratio":null,"active":null,'
        + '"home":{"city":"","zip":0},"work":null,"tags":[],"ids":[],'
        + '"scores":[],"flags":[],"past":[]}',
    )
    assert_equal(_text(ByField(_empty())), _text(ByHand(_empty())))


@fieldwise_init
struct Literals(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("i", 1)
        out.field("f", 1.5)
        out.field("b", True)
        out.field("s", "x")
        out.field("l", ["a"])
        var e: List[Int] = [1, 2]  # `[1, 2]` itself is ambiguous
        out.field("e", e)
        out.end_object()


def test_literals_choose_an_overload() raises:
    assert_equal(
        _text(Literals()),
        '{"i":1,"f":1.5,"b":true,"s":"x","l":["a"],"e":[1,2]}',
    )


struct Tokens(Movable, ToJson):
    var one: Optional[Token]
    var none: Optional[Token]
    var many: List[Token]

    def __init__(out self):
        self.one = Optional(Token("t"))
        self.none = Optional[Token]()
        self.many = List[Token]()
        self.many.append(Token("u"))
        self.many.append(Token("v"))

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("one", self.one)
        out.field("none", self.none)
        out.field("many", self.many)
        out.end_object()


def test_move_only_elements() raises:
    assert_equal(_text(Tokens()), '{"one":"t","none":null,"many":["u","v"]}')


@fieldwise_init
struct Ids(ToJson):
    """A top-level array, through `value`."""

    var ids: List[Int]

    def write_json(self, mut out: JsonWriter) raises:
        out.value(self.ids)


def test_value_writes_outside_an_object() raises:
    assert_equal(_text(Ids([3, 4])), "[3,4]")
    var r = Json(Ids([5]), status=201).to_response()
    assert_equal(r.status, 201)
    assert_equal(r.text(), "[5]")
    assert_equal(r.headers.get("content-type").value(), "application/json")


def test_field_keeps_the_structure_rules() raises:
    # Each misuse raises, as with `name` and the explicit value calls.
    for i in range(5):
        var out = JsonWriter()
        var raised = False
        try:
            if i == 0:
                out.field("a", 1)  # outside an object
            elif i == 1:
                out.begin_array()
                out.field("a", 1)  # inside an array
            elif i == 2:
                out.begin_object()
                out.field("a", 1)
                out.field("a", Optional[Int]())
                out.end_object()  # repeated name
            elif i == 3:
                out.begin_object()
                out.field("f", Optional[Float64](Float64(0) / Float64(0)))
            else:
                var l: List[Float64] = [1.0, Float64(1e300) * 1e300]
                out.begin_object()
                out.field("l", l)
        except:
            raised = True
        assert_true(raised, String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
