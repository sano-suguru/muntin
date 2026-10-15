"""The users API that scripts/compare_dx.sh specifies, written with Muntin.

`scripts/compare_dx.sh` serves it with Muntin's Flare adapter on the port
given as the first argument and sends it the specification's requests;
bench/compare/users_flare.mojo is the same API written against Flare alone.
"""

from std.sys import argv

from muntin import (
    App,
    FromJson,
    Json,
    JsonValue,
    JsonWriter,
    Param,
    Response,
    State,
    ToErrorResponse,
    ToJson,
)
from muntin_flare import Server


@fieldwise_init
struct User(Copyable, ToJson):
    var id: Int
    var name: String
    var age: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.name("age")
        out.int(self.age)
        out.end_object()


@fieldwise_init
struct UserList(ToJson):
    var users: List[User]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_array()
        for u in self.users:
            u.write_json(out)
        out.end_array()


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string(), value["age"].int())


@fieldwise_init
struct NotFound(ToErrorResponse):
    var id: Int

    def to_error_response(deinit self) -> Response:
        return Response.text("no user " + String(self.id), status=404)


@fieldwise_init
struct Users(Movable):
    var all: List[User]


def list_users(users: State[Users], limit: Optional[Int]) -> Json[UserList]:
    var out = List[User]()
    for u in users[].all:
        if len(out) == limit.or_else(10):
            break
        out.append(u.copy())
    return Json(UserList(out^))


def get_user(users: State[Users], id: Int) raises NotFound -> Json[User]:
    for u in users[].all:
        if u.id == id:
            return Json(u.copy())
    raise NotFound(id)


def get_post(uid: Param["uid", Int], pid: Param["pid", Int]) -> String:
    return String("post ", pid.value, " of user ", uid.value)


def create_user(users: State[Users], body: Json[CreateUser]) -> Json[User]:
    var id = len(users[].all) + 1
    return Json(User(id, body.value.name, body.value.age), status=201)


def main() raises:
    var users = State(
        Users([User(1, "Ada", 36), User(2, "Bo", 41), User(3, "Cy", 29)])
    )
    var app = App()
    app.get["/users?{limit}"](list_users, users)
    app.get["/users/{id}"](get_user, users)
    app.get["/users/{uid}/posts/{pid}"](get_post)
    app.post["/users"](create_user, users)
    var server = Server.bind("127.0.0.1", Int(argv()[1]))
    server.serve(app)
