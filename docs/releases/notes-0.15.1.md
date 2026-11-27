Keg 0.15.1 tells an app's agent whether a mailed sender is genuine, lets a member of an app's organisation hold more than one role, shows an app's agents' threads in the console, and makes `docker run --init` work as it does with Docker. It fixes what a full or failing disk did to a node, and what an outside review found before release. Everything new is **experimental and off** until you turn it on: see "Experimental" below.

## New

- **Whether a mailed sender is genuine.** Mail-in checks SPF, DKIM and DMARC as a message arrives and writes the verdict with it: each check's result, and `from_verified`, true only when DMARC passes. An agent asks `keg.mail_from_verified(event)` or `keg.mail_verified_sender(event)`, and is answered only of mail it may read. Map a sender to a member only when it is verified.
- **A member may hold more than one role.** Each keeps the one role they had; an administrator grants more (`keg.grant_role`, `keg.take_role`), and every check of a role reads the whole set: asks, approvals, organisations' tools, audiences, replays, and `keg.actor_has_role(R)` in a policy. A supervisor who is also an agent can read the ticket they decide on. `keg app members`, the console and the Mac app show them.
- **An app's agents' threads, in the console.** Apps → an app → an environment → Threads: each thread's agent, organisation, state, what it waits for and until when, and spend; its events, labelled by who wrote each; its asks, their arguments as Keg writes them out; and Wake, Stop and a dry Replay.
- **`docker run --init` and `keg run --init`.** PID 1 is Keg's own small init, as Docker's is: it reaps orphans, passes signals on and ends with the command's status. It runs from a sealed copy in memory and holds nothing of the node's.
- **Webhooks on a Mac node**, or any node with no public name: deliveries are taken at the node's local names port, which the Mac forwards to its own localhost. `keg app hooks` says where to point a tunnel.
- **`keg app check [NAME]`** runs a project's check as a piece of work's gate does, with its own database and a fake model, on a read-only copy of your folder.
- **Agents wait for what is theirs.** `thread.waitFor` and `thread.listen` take `match`, so a thread waits for the reply to its own message and nothing else wakes it. A thread's own tools read the event that started or woke it. A thread an emitted event starts outlives the agent that emitted it, held to that agent's lineage: one budget, at most 100 threads, all stopped with it. A wait is written on the thread, and a wake says who woke it.
- **A node's disk sync mode**, `keg vm disk --sync full|fsync|none`, for a throwaway node such as one tests run on. `full` stays every node's default.

## Fixed

- **A full or failing disk.** A disk path given before a node's first start is used, never replaced by a new file on the Mac's internal disk. The Mac's free space is checked before a start and while the node runs. A node whose disk failed or went read-only says so plainly and takes no new work, instead of answering every write with a raw I/O error.
- **Security: from an outside review before release.** A lineage of threads stops whatever state its first thread is in, and only as far as the person stopping it may read; a job's events count against its lineage; turning a feature off reaches every app's database, or the node names the one it could not tell; every invisible character in what an ask shows is written out, and a secret is hidden before anything is; one sender or a web page cannot stop webhook deliveries at a node with no public name; `keg app check` reads only inside its project.
- Mail sent to a Mac node from the Mac itself arrives. Every certificate the node signs is accepted by strict clients such as Python 3.13. Keg services no longer offer the old models service to install. `keg vm` acts on the node its `--socket` names. A firewall rule is no longer put back for a node that is gone, and a container's network allowance is checked before its image is fetched.

## Experimental

New in this release, each off until you turn it on with `keg settings experimental on NAME` or in Settings › Experimental. The switches of 0.15.0 are as they were. See [EXPERIMENTAL.md](../EXPERIMENTAL.md).

- `mail-verdict`: SPF, DKIM and DMARC for mail in (needs `mail`).
- `member-roles`: members with more than one role.
- `app-check`: `keg app check`.

## Known in this release

- The console's and the Mac app's own escaping, used where a node gives no escaped form, still writes out fewer invisible characters than the node does.
- A vault entry set before 0.15.1 is hidden in its written-out form only once it is set again.
- On a Mac, `--sync fsync` and `none` can lose what the VM wrote last if the power goes or an external disk is cut off: use them only for a node nothing on is worth keeping.
- The translations were made by machine and checked for completeness and their blanks only.

## Upgrading from 0.15.0

- `keg update`, then restart the node (`sudo systemctl restart kegd`). On a Mac the app updates itself; then Stop Keg and Start Keg.
- Each app's database that uses agents is given capability files 026 to 031 at its next deploy. Run `keg app client` in an app that uses `@keg/app` to bring its client up to date.
- Everything new is off until you turn it on; a node's disk stays synced `full`.

See [keg.rahultrikha.com](https://keg.rahultrikha.com) for more.
