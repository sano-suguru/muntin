"""The users API that scripts/compare_dx.sh specifies, written against Flare
alone.

`scripts/compare_dx.sh` serves it with Flare's `HttpServer` on the port
given as the first argument and sends it the specification's requests;
bench/compare/users_muntin.mojo is the same API written with Muntin. It uses
Flare's typed extractors (`Extracted`, `State`, `PathInt`, `JsonAs`) and the
reflection-based JSON codec Flare ships (`json`), as Flare's README shows
typed extractors and state.
"""

from std.sys import argv

from json import Value, deserialize_value, serialize_json
from flare.http import (
    Extracted,
    FromJson,
    Handler,
    HttpServer,
    JsonAs,
    OptionalQueryInt,
    PathInt,
    Request,
    Response,
    Router,
    State,
    Status,
    ok,
    ok_json,
)
from flare.net import SocketAddr


@fieldwise_init
struct User(Copyable):
    var id: Int
    var name: String
    var age: Int


@fieldwise_init
struct CreateUser(Copyable, Defaultable, FromJson):
    var name: String
    var age: Int

    def __init__(out self):
        self = Self("", 0)

    def parse_json(mut self, value: Value) raises:
        self = deserialize_value[Self](value)


@fieldwise_init
struct Users(Copyable, Defaultable):
    var all: List[User]

    def __init__(out self):
        self.all = []


@fieldwise_init
struct ListUsers(Copyable, Defaultable, Handler):
    var users: State[Users]
    var limit: OptionalQueryInt["limit"]

    def __init__(out self):
        self.users = State[Users]()
        self.limit = OptionalQueryInt["limit"]()

    def serve(self, req: Request) raises -> Response:
        var out = List[User]()
        for u in self.users.value.all:
            if len(out) == self.limit.value.or_else(10):
                break
            out.append(u.copy())
        return ok_json(serialize_json(out))


@fieldwise_init
struct GetUser(Copyable, Defaultable, Handler):
    var users: State[Users]
    var id: PathInt["id"]

    def __init__(out self):
        self.users = State[Users]()
        self.id = PathInt["id"]()

    def serve(self, req: Request) raises -> Response:
        for u in self.users.value.all:
            if u.id == self.id.value:
                return ok_json(serialize_json(u))
        var resp = ok("no user " + String(self.id.value))
        resp.status = Status.NOT_FOUND
        resp.reason = "Not Found"
        return resp^


@fieldwise_init
struct GetPost(Copyable, Defaultable, Handler):
    var uid: PathInt["uid"]
    var pid: PathInt["pid"]

    def __init__(out self):
        self.uid = PathInt["uid"]()
        self.pid = PathInt["pid"]()

    def serve(self, req: Request) raises -> Response:
        return ok(String("post ", self.pid.value, " of user ", self.uid.value))


@fieldwise_init
struct CreateUserHandler(Copyable, Defaultable, Handler):
    var users: State[Users]
    var body: JsonAs[CreateUser]

    def __init__(out self):
        self.users = State[Users]()
        self.body = JsonAs[CreateUser]()

    def serve(self, req: Request) raises -> Response:
        var id = len(self.users.value.all) + 1
        ref b = self.body.value
        var resp = ok_json(serialize_json(User(id, b.name, b.age)))
        resp.status = Status.CREATED
        resp.reason = "Created"
        return resp^


def main() raises:
    var users = State(
        Users([User(1, "Ada", 36), User(2, "Bo", 41), User(3, "Cy", 29)])
    )
    var r = Router()
    r.get(
        "/users",
        Extracted(ListUsers(users.copy(), OptionalQueryInt["limit"]())),
    )
    r.get("/users/:id", Extracted(GetUser(users.copy(), PathInt["id"]())))
    r.get("/users/:uid/posts/:pid", Extracted[GetPost]())
    r.post(
        "/users",
        Extracted(CreateUserHandler(users.copy(), JsonAs[CreateUser]())),
    )
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(Int(argv()[1]))))
    srv.serve(r^)
