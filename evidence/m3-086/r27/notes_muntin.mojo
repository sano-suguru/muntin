"""The notes application of bench/compare/notes, written with Muntin as it is
now: its users behind a guarded group, its JSON derived from its DTOs' fields,
and each 400 Muntin answers before a handler logged with its cause.

scripts/compare_authors.py hands it, as notes_muntin.mojo, to the authors of
M3-086, and checks what they deliver; it is started as
`PROGRAM PORT JOURNAL TOKENS MAX_TEXT`. store.mojo, the storage and
configuration, is bench/compare/notes/store.mojo.
"""

from std.sys import stderr

from muntin import (
    App,
    Group,
    Headers,
    Json,
    JsonFields,
    Next,
    Request,
    Response,
    State,
    ToErrorResponse,
)
from muntin_flare import Server

from store import Accounts, Config, Note, Store


@fieldwise_init
struct Service(Movable):
    var store: Store
    var accounts: Accounts
    var max_text: Int


@fieldwise_init
struct ApiError(Movable, ToErrorResponse):
    var status: Int
    var message: String

    def to_error_response(deinit self) -> Response:
        var response = Response.text(self.message, status=self.status)
        if self.status == 401:
            try:
                response.headers.add("WWW-Authenticate", "Bearer")
            except:
                pass  # `add` raises only for an invalid name or value
        return response^


# The authenticated user, which the group's guard hands each handler.
@fieldwise_init
struct User(Movable):
    var name: String


# The store's Note conforms to nothing of Muntin's: these are the API's own.
@fieldwise_init
struct NoteJson(JsonFields):
    var id: Int
    var owner: String
    var text: String


def note_json(note: Note) -> NoteJson:
    return NoteJson(note.id, note.owner, note.text)


@fieldwise_init
struct NewNote(JsonFields):
    var text: String


# GET /me: the caller and how many notes they own, members in that order.
@fieldwise_init
struct MeJson(JsonFields):
    var user: String
    var notes: Int


def authenticate(svc: State[Service], headers: Headers) raises ApiError -> User:
    var field = headers.get("authorization").or_else("")
    if field.lower().startswith("bearer "):  # RFC 9110 §11.1: any case
        var user = svc[].accounts.user(String(field[byte=7:]))
        if user:
            return User(user.value())
    raise ApiError(401, "Unauthorized")


def log_rejections(var request: Request, var next: Next) raises -> Response:
    var target = String(request.method, " ", request.path)
    var response = next^.run(request^)
    var rejection = response.rejection()
    if rejection:
        print("rejected:", target, String(rejection.value()), file=stderr)
    return response^


def stored(svc: Service, owner: String, text: String) raises ApiError -> Note:
    try:
        return svc.store.add(owner, text)
    except e:
        print("storage:", e, file=stderr)
        raise ApiError(503, "storage unavailable")


def list_notes(svc: State[Service], user: User) -> Json[List[NoteJson]]:
    var notes = List[NoteJson]()
    for note in svc[].store.owned_by(user.name):
        notes.append(note_json(note))
    return Json(notes^)


def me(svc: State[Service], user: User) -> Json[MeJson]:
    return Json(MeJson(user.name, len(svc[].store.owned_by(user.name))))


def get_note(
    svc: State[Service], user: User, id: Int
) raises ApiError -> Json[NoteJson]:
    var note = svc[].store.get(id)
    if not note or note.value().owner != user.name:
        raise ApiError(404, String("no note ", id))
    return Json(note_json(note.value()))


def create_note(
    svc: State[Service], user: User, body: Json[NewNote]
) raises ApiError -> Json[NoteJson]:
    ref text = body.value.text
    if text.byte_length() > svc[].max_text:
        raise ApiError(422, "text too long")
    return Json(note_json(stored(svc[], user.name, text)), status=201)


def main() raises:
    var config = Config.from_args()
    var svc = State(
        Service(
            Store.open(config.journal),
            Accounts.load(config.tokens),
            config.max_text,
        )
    )
    var app = App()
    app.use(log_rejections)
    var users = Group(authenticate, svc)
    users.get["/me"](me, svc)
    users.get["/notes"](list_notes, svc)
    users.get["/notes/{id}"](get_note, svc)
    users.post["/notes"](create_note, svc)
    app.mount(users^)
    var server = Server.bind("127.0.0.1", config.port)
    server.serve(app)
