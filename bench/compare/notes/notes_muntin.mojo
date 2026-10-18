"""The notes application that scripts/compare_notes.py specifies, written
with Muntin.

`scripts/compare_notes.py` serves it with Muntin's Flare adapter, started as
`PROGRAM PORT JOURNAL TOKENS MAX_TEXT`, and drives it through its scenario;
bench/compare/notes/notes_flare.mojo is the same application written against
Flare alone, and store.mojo the storage and configuration both share.
"""

from std.sys import stderr

from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Response,
    State,
    ToErrorResponse,
    ToJson,
    WithHeaders,
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


# The store's Note conforms to nothing of Muntin's, so the response wraps it.
@fieldwise_init
struct NoteJson(ToJson):
    var note: Note

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("id", self.note.id)
        out.field("owner", self.note.owner)
        out.field("text", self.note.text)
        out.end_object()


@fieldwise_init
struct NoteList(ToJson):
    var notes: List[Note]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_array()
        for note in self.notes:
            NoteJson(note.copy()).write_json(out)
        out.end_array()


@fieldwise_init
struct NewNote(FromJson):
    var text: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["text"].string())


def authenticate(svc: Service, headers: Headers) raises ApiError -> String:
    var field = headers.get("authorization").or_else("")
    if field.startswith("Bearer "):
        var user = svc.accounts.user(String(field.removeprefix("Bearer ")))
        if user:
            return user.value()
    raise ApiError(401, "Unauthorized")


def stored(svc: Service, owner: String, text: String) raises ApiError -> Note:
    try:
        return svc.store.add(owner, text)
    except e:
        print("storage:", e, file=stderr)
        raise ApiError(503, "storage unavailable")


def list_notes(
    svc: State[Service], headers: Headers
) raises ApiError -> Json[NoteList]:
    var user = authenticate(svc[], headers)
    return Json(NoteList(svc[].store.owned_by(user)))


def get_note(
    svc: State[Service], id: Int, headers: Headers
) raises ApiError -> Json[NoteJson]:
    var user = authenticate(svc[], headers)
    var note = svc[].store.get(id)
    if not note or note.value().owner != user:
        raise ApiError(404, String("no note ", id))
    return Json(NoteJson(note.take()))


def create_note(
    svc: State[Service], input: WithHeaders[Json[NewNote]]
) raises ApiError -> Json[NoteJson]:
    var user = authenticate(svc[], input.headers)
    ref text = input.body.value.text
    if text.byte_length() > svc[].max_text:
        raise ApiError(422, "text too long")
    return Json(NoteJson(stored(svc[], user, text)), status=201)


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
    app.get["/notes"](list_notes, svc)
    app.get["/notes/{id}"](get_note, svc)
    app.post["/notes"](create_note, svc)
    var server = Server.bind("127.0.0.1", config.port)
    server.serve(app)
