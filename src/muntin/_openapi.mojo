"""OpenAPI operations (M3-091).

`_operation[A, B, C, R]` writes the OpenAPI 3.1 operation object of a route
whose request slots have types `A`, `B` and `C` (`_NoSlot` where there is
none) and whose result has type `R`, from those types alone: the route
values as parameters, named by the literal's placeholders in binding
order; the body as the request body; the result as the responses. `_route`
in `app.mojo` stores it in the route, so the document costs nothing until
`App.openapi` asks for it. It says only what `App.handle` does: a
`Json[T]` result's status is chosen at run time, so it is the `2XX`
response (Muntin's own answers are never 2xx); a hand-written codec's
schema is `{}`. Not described: a `Json` answer with another status,
Muntin's own answers (listed in docs/reference/openapi.md), middleware and
a group's guard; the application adds those through `App.openapi`'s
`operations` (`_merge`), an explicit status taking precedence over `2XX`.
A `Json` answer of 204 or 205 has no body (M3-093), which the derived
`2XX` describes with content: the application describes it through an
addition.
"""

from std.reflection import reflect

from ._registration_rules import (
    _BODY,
    _INT,
    _OPT_INT,
    _kind,
    _is_optional,
    _is_value,
    _path_params,
    _placeholder_names,
)
from .body import FromBytes
from .http import ToResponse
from .headers_body import _HeaderCarrier
from .json import (
    JsonValue,
    JsonWriter,
    _JsonBody,
    _bare_json,
    _write_schema,
    _ARRAY,
    _OBJECT,
    _STRING,
)
from .route_value import RouteValues


def _string_schema(mut out: JsonWriter, non_empty: Bool) raises:
    out.begin_object()
    out.field("type", "string")
    if non_empty:
        out.field("minLength", 1)
    out.end_object()


def _parameter[
    X: AnyType
](
    mut out: JsonWriter,
    names: List[StaticString],
    mut j: Int,
    paths: Int,
    mut derived: List[String],
) raises:
    """The parameter that route value `j` of type `X` binds, then `j + 1`,
    its `in` and name appended to `derived`; nothing when `X` is no route
    value."""
    comptime k = _kind[X]()
    comptime if _is_value(k):
        var place = "path" if j < paths else "query"
        derived.append(place + " " + String(names[j]))
        out.begin_object()
        out.field("name", String(names[j]))
        out.field("in", place)
        out.field("required", not _is_optional(k))
        comptime if _is_optional(k):
            # An empty value, or a key without `=`, reads as `None`, as an
            # absent key does; a present value meets the schema.
            out.field("allowEmptyValue", True)
            out.field(
                "description", "An empty value is the same as an absent one."
            )
        out.name("schema")
        comptime if k == _INT or k == _OPT_INT:
            out.begin_object()
            out.field("type", "integer")
            out.field("format", "int64")
            out.field("minimum", Int.MIN)
            out.field("maximum", Int.MAX)
            out.end_object()
        else:
            # `String` and a `FromRouteValue` type read the decoded text,
            # never empty: a required empty value is 400, an optional one
            # `None` (`allowEmptyValue` above).
            _string_schema(out, True)
        out.end_object()
        j += 1


def _parameters[
    A: AnyType, B: AnyType, C: AnyType
](
    mut out: JsonWriter, literal: StaticString, extra: Optional[JsonValue]
) raises:
    """The route values' parameters, then the application's own (`extra`'s
    `parameters` entries, say a header field a handler reads), which may
    not repeat a derived one's `in` and name."""
    var names = _placeholder_names(literal)
    var paths = _path_params(literal)
    var j = 0
    var derived = List[String]()
    out.name("parameters")
    out.begin_array()
    comptime if conforms_to(A, RouteValues):
        comptime r = reflect[A]
        comptime types = r.field_types()
        comptime for i in range(r.field_count()):
            _parameter[types[i]](out, names, j, paths, derived)
    else:
        _parameter[A](out, names, j, paths, derived)
    _parameter[B](out, names, j, paths, derived)
    _parameter[C](out, names, j, paths, derived)
    if extra:
        var more = extra.value().get("parameters")
        if more:
            if more.value()._kind() != _ARRAY:
                raise Error("parameters is not a JSON array")
            for i in range(len(more.value())):
                var item = more.value()._child(i)
                if item._kind() == _OBJECT:
                    var key = _string_member(item, "in") + " "
                    key += _string_member(item, "name")
                    for d in derived:
                        if d == key:
                            raise Error("parameter " + key + " is derived")
                out._copy(item)
    out.end_array()


def _string_member(value: JsonValue, name: String) raises -> String:
    """The string member `name` of an object, or `""`."""
    var member = value.get(name)
    if member and member.value()._kind() == _STRING:
        return member.value().string()
    return ""


def _request_body[X: AnyType](mut out: JsonWriter) raises:
    """The request body, when `X` is the body slot."""
    comptime if _kind[X]() == _BODY:
        out.name("requestBody")
        out.begin_object()
        # Only a `Json[T]` body refuses an empty one (it is not JSON); a
        # text or binary body's type decides, so Muntin requires none.
        out.field("required", conforms_to(X, _JsonBody) or _bare_json[X]())
        out.name("content")
        out.begin_object()
        comptime if _bare_json[X]():
            out.name("application/json")
            out.begin_object()
            out.name("schema")
            _write_schema[X, True](out)
            out.end_object()
        elif conforms_to(X, _JsonBody):
            out.name("application/json")
            out.begin_object()
            out.name("schema")
            X._schema[True](out)
            out.end_object()
        else:
            # Muntin checks no `Content-Type` for a text or binary body.
            out.name("*/*")
            out.begin_object()
            var bytes: Bool
            comptime if conforms_to(X, _HeaderCarrier):
                bytes = X._carries_bytes()
            else:
                bytes = conforms_to(X, FromBytes)
            if not bytes:
                out.name("schema")
                _string_schema(out, False)
            out.end_object()
        out.end_object()
        out.end_object()


def _responses[
    R: AnyType
](mut out: JsonWriter, extra: Optional[JsonValue]) raises:
    """The response `R` gives, then the application's own (`extra`'s
    `responses` members), which may not repeat the derived status."""
    out.name("responses")
    out.begin_object()
    comptime if R == String or R == StaticString:
        # No `Content-Type` field: Muntin adds none to a text result.
        out.name("200")
        out.begin_object()
        out.field("description", "The handler's text")
        out.name("content")
        out.begin_object()
        out.name("*/*")
        out.begin_object()
        out.name("schema")
        _string_schema(out, False)
        out.end_object()
        out.end_object()
        out.end_object()
    elif _bare_json[R]() and not conforms_to(R, ToResponse):
        out.name("200")
        out.begin_object()
        out.field("description", "The handler's JSON value")
        out.name("content")
        out.begin_object()
        out.name("application/json")
        out.begin_object()
        out.name("schema")
        _write_schema[R, False](out)
        out.end_object()
        out.end_object()
        out.end_object()
    elif conforms_to(R, _JsonBody):
        # `Json(value, status=)` chooses the status at run time; Muntin's
        # own answers are never 2xx. An application's
        # explicit code (say `204`) takes precedence over the range.
        out.name("2XX")
        out.begin_object()
        out.field("description", "The handler's JSON value")
        out.name("content")
        out.begin_object()
        out.name("application/json")
        out.begin_object()
        out.name("schema")
        R._schema[False](out)
        out.end_object()
        out.end_object()
        out.end_object()
    else:
        out.name("default")
        out.begin_object()
        out.field("description", "Not described: the handler's response")
        out.end_object()
    if extra:
        var more = extra.value().get("responses")
        if more:
            _merge(out, more.value())
    out.end_object()


def _operation[
    A: AnyType, B: AnyType, C: AnyType, R: AnyType
](
    mut out: JsonWriter, literal: StaticString, extra: Optional[JsonValue]
) raises:
    """The derived operation, then the application's `extra` (a parsed
    JSON object from `App.openapi`'s `operations`), as written: its
    `parameters` after the derived ones, its `responses` beside the derived
    response, its other members beside the derived ones (`_merge`)."""
    out.begin_object()
    _parameters[A, B, C](out, literal, extra)
    _request_body[A](out)
    _request_body[B](out)
    _request_body[C](out)
    _responses[R](out, extra)
    if extra:
        _merge(out, extra.value(), "parameters", "responses")
    out.end_object()


def _merge(
    mut out: JsonWriter,
    extra: JsonValue,
    skip: String = "",
    skip_too: String = "",
) raises:
    """`extra`'s members (but those named `skip` and `skip_too`, merged
    elsewhere) into the open object, after the derived ones; one that
    repeats a derived member raises: `requestBody` when the handler has a
    body slot, a response of the status the result gives, a top-level
    `openapi` or `paths`, `info`'s `title` or `version`."""
    if extra._kind() != _OBJECT:
        raise Error("not a JSON object")
    for i in range(len(extra)):
        var member = extra._child(i)
        var name = member._name()
        if name.byte_length() > 0 and (name == skip or name == skip_too):
            continue
        if out._holds(name):
            raise Error(name + " is derived")
        out.name(name)
        out._copy(member)
