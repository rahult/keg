# Example services

Two services from outside, to read, install and copy:

- [`nats`](nats/): puts the node's events, and an app's, in a NATS stream.
- [`query`](query/): keeps them in DuckDB and answers read-only SQL, with a
  token for one organization of an app.

[WRITE-A-SERVICE.md](../docs/WRITE-A-SERVICE.md) is the guide to writing
your own, and [PROTOCOL.md](../docs/PROTOCOL.md) is what a service may rely
on. Install one from its folder with `keg system install <folder>` once
`keg system builds on` has been run on the node; you are asked about each
thing it asks for.

Unlike Keg itself, these two folders are yours to copy and change: see
[LICENSE](LICENSE).
