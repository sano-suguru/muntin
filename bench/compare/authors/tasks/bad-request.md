# Task: every new note is refused

Since the last release, every `POST /notes` from the mobile app is answered
`400 Bad Request`. The app has not changed: it sends what `API.md` says, for
example `{"text":"buy milk"}` with `Content-Type: application/json` and a
valid token. Reading notes still works.

Find out why and fix it.
