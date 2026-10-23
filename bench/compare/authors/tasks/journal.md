# Task: notes lost during the disk incident

Last night the volume holding the journal was unwritable for a few minutes.
During that time clients were told their new notes were saved, some with
id 0, and those notes are gone now. Nothing about the failure is in the
service's logs.

Find out why and fix it, so the service does what `API.md` says when a write
fails.
