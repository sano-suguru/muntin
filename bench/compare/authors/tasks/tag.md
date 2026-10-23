# Task: a tag on each note

Notes get a tag, such as `home` or `work`. `store.mojo` already keeps it
(`Note.tag`, and `Store.add(owner, text, tag)`), and the journal has a column
for it; the web layer does not build against it yet.

Make the API take a tag when a note is created, required:
`POST /notes` with `{"text":"buy milk","tag":"home"}`. Every note the API
answers carries its tag after its text:
`{"id":1,"owner":"ada","text":"buy milk","tag":"home"}`. A body without a
tag is a `400`. Update `API.md` to match.
