"""OpenAPI operations (M3-091 prototype).

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
Muntin's own 400, 413 and 415 answers, middleware and a group's guard.
"""

from std.reflection import reflect

from ._registration_rules import (
    _BODY,
    _INT,
    _OPT_INT,
    _OPT_TEXT,
    _TEXT,
    _kind,
    _is_optional,
    _is_value,
    _path_params,
    _placeholder_names,
)
from .body import FromBytes
from .headers_body import _HeaderCarrier
from .http import Response
from .json import JsonWriter, _JsonBody
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
) raises:
    """The parameter that route value `j` of type `X` binds, then `j + 1`;
    nothing when `X` is no route value."""
    comptime k = _kind[X]()
    comptime if _is_value(k):
        out.begin_object()
        out.field("name", String(names[j]))
        out.field("in", "path" if j < paths else "query")
        out.field("required", not _is_optional(k))
        out.name("schema")
        comptime if k == _INT or k == _OPT_INT:
            out.begin_object()
            out.field("type", "integer")
            out.field("format", "int64")
            out.end_object()
        else:
            # `String` and a `FromRouteValue` type read the decoded text,
            # never empty: a required empty value is 400, an optional one
            # `None`.
            _string_schema(out, True)
        out.end_object()
        j += 1


def _parameters[
    A: AnyType, B: AnyType, C: AnyType
](mut out: JsonWriter, literal: StaticString) raises:
    var names = _placeholder_names(literal)
    var paths = _path_params(literal)
    var j = 0
    out.name("parameters")
    out.begin_array()
    comptime if conforms_to(A, RouteValues):
        comptime r = reflect[A]
        comptime types = r.field_types()
        comptime for i in range(r.field_count()):
            _parameter[types[i]](out, names, j, paths)
    else:
        _parameter[A](out, names, j, paths)
    _parameter[B](out, names, j, paths)
    _parameter[C](out, names, j, paths)
    out.end_array()


def _request_body[X: AnyType](mut out: JsonWriter) raises:
    """The request body, when `X` is the body slot."""
    comptime if _kind[X]() == _BODY:
        out.name("requestBody")
        out.begin_object()
        out.field("required", True)
        out.name("content")
        out.begin_object()
        comptime if conforms_to(X, _JsonBody):
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


def _responses[R: AnyType](mut out: JsonWriter) raises:
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
    elif conforms_to(R, _JsonBody):
        # `Json(value, status=)` chooses the status at run time; Muntin's
        # own answers (400, 413, 415, 500) are never 2xx.
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
    out.end_object()


def _operation[
    A: AnyType, B: AnyType, C: AnyType, R: AnyType
](mut out: JsonWriter, literal: StaticString) raises:
    out.begin_object()
    _parameters[A, B, C](out, literal)
    _request_body[A](out)
    _request_body[B](out)
    _request_body[C](out)
    _responses[R](out)
    out.end_object()
