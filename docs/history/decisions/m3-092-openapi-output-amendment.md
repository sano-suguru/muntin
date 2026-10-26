# OpenAPI output amendment (M3-092)

> **Current.** Now described in [OpenAPI reference](../../reference/openapi.md).

Status: **amendment** to "OpenAPI and schema output decision (M3-091)", made in its slice M3-092 (pull request #203, which holds the reviews that prompted it). M3-091's choice stands: `app.openapi(title=, version=, document=, operations=)` under `-D MUNTIN_OPENAPI`, each operation written from the handler's types, the application's additions as JSON objects.

**Delta to the slice** (the prototype at `a7070ad`).
- Overlapping paths raise, naming both. A request two route paths both match goes to the route of its method that matches, the most specific ([M3-053](m3-053-route-conflict-decision.md)); OpenAPI resolves it to the more specific path whatever the method, and to neither when neither covers the other. So `openapi` raises when the more specific path lacks a method of the more general one (`GET /a/{x}` beside `POST /a/b`), and when neither covers the other (`/a/{x}` and `/{y}/b`).
- An operation's `parameters` addition is appended after the derived parameters instead of raising `parameters is derived`; an entry that repeats a derived parameter's `in` and name raises. The header fields a raw, `Headers` or `WithHeaders` handler reads, and a raw handler's query keys, can then be described, as M3-091's pull request said additions could.
- A static segment that is a dot segment written with `%2e` or `%2E` (`%2e`, `.%2E`, `%2e%2e`) is refused as `.` and `..` are, since WHATWG URL clients remove it too.

**Why.** Without the first and third, the document says a request exists that Muntin answers otherwise or never receives; without the second, an addition M3-091 meant to allow raises.

**Boundary.** No signature changes, nor the define, nor the derived output of any kind. A document `openapi` returned before comes out the same unless its routes overlap as above, a segment is such a dot segment, or an addition gives `parameters`.

**Revisit when**: M3-091's conditions, or OpenAPI states how a request that templated paths of different specificity both match resolves.
