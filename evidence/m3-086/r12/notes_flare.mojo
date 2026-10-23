"""The notes application that scripts/compare_notes.py specifies, written
against Flare alone.

`scripts/compare_notes.py` serves it with Flare's `HttpServer`, started as
`PROGRAM PORT JOURNAL TOKENS MAX_TEXT`, and drives it through its scenario;
bench/compare/notes/notes_muntin.mojo is the same application written with
Muntin, and store.mojo the storage and configuration both share. It uses
Flare's typed extractors (`Extracted`, `State`, `PathInt`, `JsonAs`), its
Bearer parser and the reflection-based JSON codec Flare ships (`json`); the
authenticated user is an extractor of its own, `CurrentUser`.
"""

from std.sys import stderr

from json import Value, deserialize_value, serialize_json
from flare.http import (
    Extracted,
    Extractor,
    FromJson,
    Handler,
    HttpServer,
    JsonAs,
    PathInt,
    Request,
    Response,
    Router,
    State,
    ok,
    ok_json,
)
from flare.http.auth_extract import AuthError, parse_bearer_token
from flare.net import SocketAddr

from store import Accounts, Config, Note, Store


@fieldwise_init
struct Service(Copyable, Defaultable):
    var store: Store
    var accounts: Accounts
    var max_text: Int

    def __init__(out self):
        self = Self(Store(), Accounts(), 0)


# Flare's HttpStatusError would answer "404 no note 1" and close the
# connection, so the answers the scenario specifies are built here.
def text(status: Int, reason: String, body: String) -> Response:
    var resp = ok(body)
    resp.status = status
    resp.reason = reason
    return resp^


# The user a request's Bearer token names. A missing, malformed or unknown
# token raises an `AuthError`, which `Extracted` answers with 401 before the
# handler runs.
@fieldwise_init
struct CurrentUser(Copyable, Defaultable, Extractor):
    var accounts: Accounts
    var name: String

    def __init__(out self):
        self = Self(Accounts(), "")

    def apply(mut self, req: Request) raises:
        var token = parse_bearer_token(req.headers.get("authorization"))
        var user = self.accounts.user(token)
        if not user:
            raise AuthError.EMPTY_TOKEN  # the closest public variant
        self.name = user.value()


@fieldwise_init
struct NewNote(Copyable, Defaultable, FromJson):
    var text: String
    var tag: String

    def __init__(out self):
        self = Self("", "")

    def parse_json(mut self, value: Value) raises:
        self = deserialize_value[Self](value)


@fieldwise_init
struct ListNotes(Copyable, Defaultable, Handler):
    var svc: State[Service]
    var user: CurrentUser

    def __init__(out self):
        self = Self(State[Service](), CurrentUser())

    def serve(self, req: Request) raises -> Response:
        var notes = self.svc.value.store.owned_by(self.user.name)
        return ok_json(serialize_json(notes))


@fieldwise_init
struct GetNote(Copyable, Defaultable, Handler):
    var svc: State[Service]
    var user: CurrentUser
    var id: PathInt["id"]

    def __init__(out self):
        self = Self(State[Service](), CurrentUser(), PathInt["id"]())

    def serve(self, req: Request) raises -> Response:
        var note = self.svc.value.store.get(self.id.value)
        if not note or note.value().owner != self.user.name:
            return text(404, "Not Found", String("no note ", self.id.value))
        return ok_json(serialize_json(note.value()))


@fieldwise_init
struct CreateNote(Copyable, Defaultable, Handler):
    var svc: State[Service]
    var user: CurrentUser
    var body: JsonAs[NewNote]

    def __init__(out self):
        self = Self(State[Service](), CurrentUser(), JsonAs[NewNote]())

    def serve(self, req: Request) raises -> Response:
        ref svc = self.svc.value
        ref note_text = self.body.value.text
        if note_text.byte_length() > svc.max_text:
            return text(422, "Unprocessable Content", "text too long")
        var note: Note
        try:
            note = svc.store.add(
                self.user.name, note_text, self.body.value.tag
            )
        except e:
            print("storage:", e, file=stderr)
            return text(503, "Service Unavailable", "storage unavailable")
        var resp = ok_json(serialize_json(note))
        resp.status = 201
        resp.reason = "Created"
        return resp^


def main() raises:
    var config = Config.from_args()
    var svc = State(
        Service(
            Store.open(config.journal),
            Accounts.load(config.tokens),
            config.max_text,
        )
    )
    var user = CurrentUser(svc.value.accounts.copy(), "")
    var r = Router()
    r.get("/notes", Extracted(ListNotes(svc.copy(), user.copy())))
    r.get(
        "/notes/:id",
        Extracted(GetNote(svc.copy(), user.copy(), PathInt["id"]())),
    )
    r.post(
        "/notes",
        Extracted(CreateNote(svc.copy(), user.copy(), JsonAs[NewNote]())),
    )
    var srv = HttpServer.bind(SocketAddr.localhost(UInt16(config.port)))
    srv.serve(r^)
