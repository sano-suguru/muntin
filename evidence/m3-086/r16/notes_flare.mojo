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

from std.ffi import c_int, external_call, get_errno
from std.memory import ArcPointer
from std.os.path import exists, getsize
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

from store import Accounts, Config, Note, Store, _escaped


struct Journal(Copyable, Defaultable):
    """Checks that each `Store.add` put its note's line in the journal.

    `Store.add` raises only when the journal cannot be opened: Mojo's
    `FileHandle.write` and `close` do not report a failed write(2), so a
    write that fails after the open (a full or failing volume) returns the
    note as stored while its line, or part of it, never reached the file.
    `check` reads back what the add appended; when it is not the note's
    line, the caller drops the note and `undo` cuts the journal back to its
    length before the add, or, when that fails too, before the next write
    (`repair`), so a partial line is never followed by another note.
    The server runs one worker, so no other write comes between the size
    taken before an add and the check after it.
    """

    var path: String
    var _repair_at: ArcPointer[Int]
    """The length to cut the journal back to before the next write; -1 when
    it needs no repair. Shared by copies, as the store is."""

    def __init__(out self):
        self = Self("")

    def __init__(out self, path: String):
        self.path = path
        self._repair_at = ArcPointer(-1)

    def size(self) raises -> Int:
        return getsize(self.path) if exists(self.path) else 0

    def repair(self) raises:
        """Cuts off what a failed write left, if `undo` could not."""
        if self._repair_at[] >= 0:
            self._truncate(self._repair_at[])
            self._repair_at[] = -1

    def check(self, start: Int, note: Note) raises:
        """Raises unless the journal is `note`'s line appended at `start`."""
        var line = String(note.id, "\t", note.owner, "\t", _escaped(note.text), "\n")
        var size = self.size()
        if size == start + line.byte_length():
            with open(self.path, "r") as f:
                _ = f.seek(start)
                if f.read() == line:
                    return
        raise Error(
            "journal ",
            self.path,
            ": note ",
            note.id,
            " not written (",
            size - start,
            " of ",
            line.byte_length(),
            " bytes appended)",
        )

    def undo(self, start: Int):
        """Cuts the journal back to `start`, now or before the next write."""
        try:
            if not exists(self.path) or getsize(self.path) != start:
                self._truncate(start)
        except e:
            print("notes: journal", self.path, "left unrepaired:", e, file=stderr)
            self._repair_at[] = start

    def _truncate(self, length: Int) raises:
        var path = self.path.copy()  # as_c_string_span() is mutating
        if external_call["truncate", c_int](
            path.as_c_string_span(), Int64(length)
        ) != 0:
            var errno = Int(get_errno().value)
            raise Error(
                "journal ", self.path, ": truncate to ", length, " bytes: errno ", errno
            )


@fieldwise_init
struct Service(Copyable, Defaultable):
    var store: Store
    var journal: Journal
    var accounts: Accounts
    var max_text: Int

    def __init__(out self):
        self = Self(Store(), Journal(), Accounts(), 0)


# Flare's HttpStatusError would answer "404 no note 1" and close the
# connection, so the answers the scenario specifies are built here.
def text(status: Int, reason: String, body: String) -> Response:
    var resp = ok(body)
    resp.status = status
    resp.reason = reason
    return resp^


# A write to the journal failed: its cause goes to standard error.
def unavailable(cause: Error) -> Response:
    print("notes: POST /notes:", cause, file=stderr)
    return text(503, "Service Unavailable", "storage unavailable")


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

    def __init__(out self):
        self = Self("")

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
        # A note whose write fails is not kept, and its client is told so
        # (API.md, "Storage"): never answer 201 for a note not in the journal.
        var start: Int
        try:
            svc.journal.repair()
            start = svc.journal.size()
        except e:
            return unavailable(e)
        var note: Note
        try:
            note = svc.store.add(self.user.name, note_text)
        except e:
            return unavailable(e)  # the store kept nothing
        try:
            svc.journal.check(start, note)
        except e:
            # The store kept the note in memory: drop it (the store has no
            # call for that), so the next note takes its id.
            _ = svc.store._data[].notes.pop()
            svc.journal.undo(start)
            return unavailable(e)
        var resp = ok_json(serialize_json(note))
        resp.status = 201
        resp.reason = "Created"
        return resp^


def main() raises:
    var config = Config.from_args()
    var svc = State(
        Service(
            Store.open(config.journal),
            Journal(config.journal),
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
