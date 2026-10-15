"""The request header rebuild M3-066 chooses, as a prototype (pull request
#119). Not part of Muntin, and not used by the adapter: the M3-067 slice
moves it into `adapters/flare/muntin_flare.mojo` and deletes this file.
`write_to_pieces.mojo` tests it; `bench/headers/bench_headers.mojo`
measures it beside the adapter's `to_muntin_headers`, and
`scripts/bench_headers.sh` serves it over loopback through a copy of the
adapter (`bench/headers/pieces_adapter.py`).

Flare v0.12.0's `HeaderMap.write_to` calls
`writer.write(name, ": ", value, "\\r\\n")` once per field, and a `Writer`
receives that as four `write_string` calls, one per piece. That split is
how v0.12.0 is written, not a documented contract of `HeaderMap`: it is a
compatibility condition of the pinned Flare, which `write_to_pieces.mojo`
pins and `write_to_splits_fields` checks at run time. Reading the fields
by position from the pieces needs no parse at a colon and no by-name
lookup, so it is linear in the fields' bytes.
"""

from std.collections import Optional
from std.format import Writer

from flare.http import HeaderMap
from muntin import Headers


struct FieldPieces(Writer):
    """What `HeaderMap.write_to` writes, one piece per write: the bytes in
    one buffer and each piece's end in `ends`."""

    var bytes: List[UInt8]
    var ends: List[Int]

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.ends = List[Int]()

    def write_string(mut self, string: StringSlice):
        self.bytes.extend(string.as_bytes())
        self.ends.append(len(self.bytes))


def _piece_is(p: FieldPieces, start: Int, end: Int, text: StringSlice) -> Bool:
    var t = text.as_bytes()
    if end - start != len(t):
        return False
    for i in range(len(t)):
        if p.bytes[start + i] != t[i]:
            return False
    return True


def pieces_match(p: FieldPieces, fields: Int) -> Bool:
    """Whether `p` is four pieces per field, the second `": "` and the
    fourth CRLF: what Flare v0.12.0's `write_to` writes."""
    if len(p.ends) != 4 * fields:
        return False
    for k in range(fields):
        var e = 4 * k
        if not _piece_is(p, p.ends[e], p.ends[e + 1], ": "):
            return False
        if not _piece_is(p, p.ends[e + 2], p.ends[e + 3], "\r\n"):
            return False
    return True


def rebuild(p: FieldPieces, fields: Int) raises -> Optional[Headers]:
    """`None` when the pieces are not what `pieces_match` accepts (a Flare
    that writes fields another way: the server's fault, not the client's);
    else exactly the fields, or a raise when one cannot be represented (a
    name or value that is not UTF-8, or that `Headers.add` refuses, a name
    with `:` included: the client's)."""
    if not pieces_match(p, fields):
        return None
    var headers = Headers()
    var start = 0
    for k in range(fields):
        var e = 4 * k
        var name = String(from_utf8=Span(p.bytes)[start : p.ends[e]])
        var value = String(
            from_utf8=Span(p.bytes)[p.ends[e + 1] : p.ends[e + 2]]
        )
        headers.add(name, value)
        start = p.ends[e + 3]
    return headers^


def rebuild_fields(headers: HeaderMap) raises -> Optional[Headers]:
    """`rebuild` of what `headers.write_to` writes."""
    var p = FieldPieces()
    headers.write_to(p)
    return rebuild(p, headers.len())


def _splits(fields: List[Tuple[String, String]]) raises -> Bool:
    var h = HeaderMap()
    for f in fields:
        h.append(f[0], f[1])
    var p = FieldPieces()
    h.write_to(p)
    if not pieces_match(p, len(fields)):
        return False
    var start = 0
    for k in range(len(fields)):
        var e = 4 * k
        if not _piece_is(p, start, p.ends[e], fields[k][0]):
            return False
        if not _piece_is(p, p.ends[e + 1], p.ends[e + 2], fields[k][1]):
            return False
        start = p.ends[e + 3]
    return True


def write_to_splits_fields() -> Bool:
    """Whether this Flare's `write_to` still writes each field as its name,
    `": "`, its value and CRLF, byte for byte: what a server would check
    once before serving. The fields are ones any Flare should accept (token
    names) whose values a change to `write_to` could misplace or alter
    while keeping four pieces: one holding `": "`, an empty one, one with
    spaces and tabs around it, one holding `;` and `=`. A name with `:` is
    pinned by `write_to_pieces.mojo` instead, so a Flare that starts
    refusing such names does not stop a server from starting. No fixed
    set of fields proves every request is read exactly; that needs Flare's
    accessor (M3-066)."""
    try:
        var fields: List[Tuple[String, String]] = [
            (String("X-Sep"), String("v: w")),
            (String("X-Empty"), String("")),
            (String("X-Space"), String(" \t v \t ")),
            (String("X-Delim"), String("1;Y=2")),
            (String("Host"), String("x")),
        ]
        return _splits(fields)
    except:
        return False
