# Notes API

The contract the notes service keeps with its clients. Every answer below is
relied on by a client; a change to one is a change to this document first.

## Every route

- A request must carry `Authorization: Bearer <token>`; the scheme is matched
  in any case (`bearer` too). The service reads its tokens at start-up, one
  `token user` pair per line of its tokens file.
- A missing, malformed or unknown token: `401`, body `Unauthorized`, and the
  field `WWW-Authenticate: Bearer`.
- A note is visible to its owner only: anyone else gets the same `404` as for
  a note that does not exist.
- JSON is sent and received as `Content-Type: application/json`. A note is
  `{"id":1,"owner":"ada","text":"buy milk","tag":"home"}`, its members in that
  order; every note answered carries its tag.
- A request the service cannot read (a path value that is not a number, a
  JSON body that is malformed or lacks a member) is `400`, body
  `Bad Request`, with its cause written to the service's standard error.

## Routes

| Request | Answer |
|---|---|
| `GET /notes` | `200`, the caller's notes, oldest first: `[{"id":1,...}]`, or `[]` |
| `GET /notes/{id}` | `200`, the note; `404`, body `no note {id}`, when there is none the caller owns |
| `POST /notes`, body `{"text":"...","tag":"..."}` (both required strings) | `201`, the note as stored, with its new id and its tag; `400` when `tag` (or `text`) is missing or not a string; `422`, body `text too long`, when the text is longer than the service's limit in bytes |

## Storage

Notes are kept in a journal file and read back at start-up. A note whose write
fails is not kept: the client gets `503`, body `storage unavailable`, the
cause is written to standard error, and the next write succeeds once the
journal can be written again. The next note takes the id the failed one did
not use.

## Running the service

    PROGRAM PORT JOURNAL TOKENS MAX_TEXT

`MAX_TEXT` is the longest text accepted, in bytes.
