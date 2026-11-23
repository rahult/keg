Keg 0.11.1 mends the console's two boxes that 0.11.0 broke, and adds what building two more apps on Keg asked for.

## Fixed

- **Ask on the console's Command page works.** In 0.11.0 the Ask button and Enter did nothing once the page had redrawn, a few seconds after it opened. Asking from the command palette was not affected.
- **The Builder's box for new work is drawn again, and the console keeps working after the Builder's first page.** In 0.11.0 it was missing, and every later redraw stopped part-way until the page was loaded again. Storage's "What is kept" now saves what was typed.
- **Security: an app cannot name a variable the node sets.** An app's `run.env` or `needs.secrets` naming `KEG_APP`, a `KEG_SERVICE_…` token or address, `KEG_REALTIME_URL`, `DATABASE_URL` or `PORT` was given to the release before the node's own value. A deploy that names one is now refused, saying which. **An app that sets a name starting with `KEG_` itself must rename it before its next deploy.**
- **`keg cleanup` no longer calls a work stopped at the gate finished**, and the node never clears one by itself; `keg cleanup --apply --works` still does when you ask.
- A port of Keg's own that moves along on a Mac no longer lands on another of the same node's ports.
- The gate's test counts list only checks that ran.
- A work's question, and its record once merged, say when `local` does not run the merged branch, and the command that makes it.
- The assistant's events tool takes an empty cursor as none.

## New

- **An event's audience can be roles and users at once**: `keg.emit(type, payload, '{"roles": ["agent"], "users": ["<id>"]}')`, and `to: { roles, users }` in `@keg/app`. Whoever is in either reads it.
- **Jobs a subscription made no longer outlive it.** `keg.off` cancels those still waiting, and `keg app jobs remove <app> --failed | --orphaned | <id>` removes what is left.
- **The assistant can read why an app's jobs failed**: counts by name and state, and the latest failed jobs' errors, cut short and with secrets hidden. Never a job's payload.
- **A Go client, and `keg app new --go`.** `keg app new --go NAME` writes a Go app to start from: a static binary on an empty image (16 MB for the example, 17 MiB of memory at rest), with Keg's Go client beside it in `third_party/keg`: sign-in, transactions as the signed-in user, events with audiences and pages, jobs, realtime for a page, tokens for a service, and helpers for gRPC. In this version gRPC reaches an app on its own port, not through its `keg.localhost` name; a page uses Connect over HTTP/1.1.

## Changed

- **Events of one transaction are read in the order they were emitted.** An event's id is now made in order; cursors handed out before still work.

## Upgrading from 0.11.0

- `keg update`, then restart the node (`sudo systemctl restart kegd`; on a Mac the app updates itself, then Stop Keg and Start Keg). Each app's database is given the three new capability files the next time the app is deployed.
- An app whose `run.env` or secrets name a variable starting with `KEG_`, or `DATABASE_URL` or `PORT` where the node sets them, is refused at its next deploy until the name is changed.

See [keg.rahultrikha.com](https://keg.rahultrikha.com) for more.
