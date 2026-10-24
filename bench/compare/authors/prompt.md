You have just joined the team that maintains a small notes web service written in Mojo. You have not used its web framework before, and nobody on the team is available to ask.

Everything you need is in the directory {WS}:

- `notes_{PROGRAM}.mojo`: the service's web layer, which is yours to change;
- `store.mojo`: its storage and configuration, owned by another team: do not change it;
- `API.md`: the contract the service keeps with its clients;
- `TASK.md`: your task;
- `build.sh`: builds `./notes`; `serve.sh PORT`: serves it on 127.0.0.1, its journal in `journal.log`, its tokens in `tokens`;
- {FRAMEWORK}.

Rules:

- Work only inside {WS}: do not read, list or search anything outside it. The Mojo toolchain `build.sh` runs is installed elsewhere; use it only through `build.sh`. Do not search the web.
- Change only `notes_{PROGRAM}.mojo` and `API.md`.
- Keep every other file you create, such as logs, journals and process ids, inside {WS}, and remove them when you finish; a temporary directory may be shared with others.
- Build, run and send requests (with curl or python3) as often as you like. Use only the ports {PORTS}. Others run their own copies of this service on this machine, also named `notes`: stop only the servers you started, by their process id, and stop every one of them before you finish.

Do the task in `TASK.md`. When you are done, `./build.sh` must succeed. Then reply with: what was wrong or what you added, the files you changed, and anything you are unsure of.
