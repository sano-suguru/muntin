"""The notes application's storage and configuration, shared by
bench/compare/notes/notes_muntin.mojo and notes_flare.mojo: nothing here
names a web framework, so both programs differ only in their web layer.

Notes live in memory and in a journal file, one line per note, written
before the note is kept: a note whose line cannot be written is not stored,
and a restart reads the journal back. The file is opened for each write, so
a journal that cannot be opened fails that write and the next one succeeds
once it can.
"""

from std.collections import Dict
from std.memory import ArcPointer
from std.os.path import exists
from std.sys import argv


@fieldwise_init
struct Note(Copyable, Defaultable):
    var id: Int
    var owner: String
    var text: String

    def __init__(out self):
        self = Self(0, "", "")


struct _Notes(Movable):
    var path: String
    var notes: List[Note]

    def __init__(out self, path: String):
        self.path = path
        self.notes = []


def _escaped(text: String) -> String:
    return text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def _unescaped(text: String) -> String:
    var out = String()
    var escape = False
    for c in text.codepoint_slices():
        if escape:
            if c == "t":
                out += "\t"
            elif c == "n":
                out += "\n"
            else:
                out += c
            escape = False
        elif c == "\\":
            escape = True
        else:
            out += c
    return out^


struct Store(Copyable, Defaultable):
    """A handle on the notes: copies share them."""

    var _data: ArcPointer[_Notes]

    def __init__(out self):
        self._data = ArcPointer(_Notes(""))

    @staticmethod
    def open(path: String) raises -> Self:
        """The notes `path` holds; none when it does not exist."""
        var store = Self()
        store._data[].path = path
        if exists(path):
            with open(path, "r") as f:
                # Not splitlines(): on Mojo 1.1.0 it also splits at a tab.
                for line in f.read().split("\n"):
                    if not line:
                        continue
                    var parts = line.split("\t")
                    store._data[].notes.append(
                        Note(
                            Int(parts[0]),
                            String(parts[1]),
                            _unescaped(String(parts[2])),
                        )
                    )
        return store^

    def add(self, owner: String, text: String) raises -> Note:
        """Writes the note to the journal, then keeps it; raises, keeping
        nothing, when the journal cannot be written."""
        ref data = self._data[]
        var id = data.notes[len(data.notes) - 1].id + 1 if data.notes else 1
        var note = Note(id, owner, text)
        try:
            with open(data.path, "a") as f:
                f.write(id, "\t", owner, "\t", _escaped(text), "\n")
        except e:
            raise Error("journal ", data.path, ": ", e)
        data.notes.append(note.copy())
        return note^

    def get(self, id: Int) -> Optional[Note]:
        for note in self._data[].notes:
            if note.id == id:
                return note.copy()
        return None

    def owned_by(self, owner: String) -> List[Note]:
        var out = List[Note]()
        for note in self._data[].notes:
            if note.owner == owner:
                out.append(note.copy())
        return out^


struct Accounts(Copyable, Defaultable):
    """Bearer tokens and the user each names, read once at start-up."""

    var _users: Dict[String, String]

    def __init__(out self):
        self._users = {}

    @staticmethod
    def load(path: String) raises -> Self:
        """`path` holds one `token user` pair per line."""
        var accounts = Self()
        with open(path, "r") as f:
            for line in f.read().split("\n"):
                if not line:
                    continue
                var parts = line.split(" ")
                accounts._users[String(parts[0])] = String(parts[1])
        return accounts^

    def user(self, token: String) -> Optional[String]:
        return self._users.get(token)


@fieldwise_init
struct Config(Copyable):
    """The start-up settings: `PROGRAM PORT JOURNAL TOKENS MAX_TEXT`."""

    var port: Int
    var journal: String
    var tokens: String
    var max_text: Int
    """The longest note text accepted, in bytes."""

    @staticmethod
    def from_args() raises -> Self:
        var args = argv()
        if len(args) != 5:
            raise Error("usage: PROGRAM PORT JOURNAL TOKENS MAX_TEXT")
        return Self(
            Int(args[1]), String(args[2]), String(args[3]), Int(args[4])
        )
