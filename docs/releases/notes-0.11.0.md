Keg 0.11.0 adds an assistant that reads your node and proposes changes you confirm, gives apps and services from outside more to work with, cleans up the node's disk, and makes the Mac's Linux machine smaller.

## New

- **An assistant, in the console and the Mac app.** Ask Keg in words, in the console's command box, its Command page or the Mac app's Command. The assistant reads what you can read on the node: containers and their logs, volumes, images, events and deliveries, work and its evidence, services, apps, machines, builds, networks, backing services, change sets, what waits for you and what takes space on the disk. It never reads a variable's or a secret's value, and a container's command line is left out. **What it reads is sent to the model's provider (OpenAI), log lines among it.**
- **Changes it proposes, which you confirm.** The assistant may propose starting, stopping, restarting, pausing, resuming or removing a container, starting or stopping a machine, retrying or skipping a delivery, fetching or removing an image, removing a volume, taking a Compose project down, and promoting or rolling back a release. Each is a card in the node's own words in Needs you. Nothing happens until you click Confirm; then the node carries out exactly what the card said, as you, once, and only within ten minutes. Removing a container a service is deployed as undeploys that service, and the card says so. A promotion or rollback into an environment that applies releases without approval is deployed at once, and the card says that too.
- **What it can never do:** approve anything, install or remove a service, read or set a secret, change its own key or spending limits, clean up, share anything, or confirm its own proposals.
- **Off until you set it up.** `keg assistant setup --env-file <path to a .env>` reads your OpenAI key once and seals it for Keg's model gateway. Spending is held to $5 a day for the assistant and $20 for the node unless you change it with `keg assistant limits`; `keg assistant usage` shows what was spent. **Anyone with the console's link can read the conversations and confirm the changes:** treat the link as the node's key.
- **Services from outside you can trust with more.** Tokens for an app and for one organization of it, so a page reads only its own organization's events; readers kept to their own account and limits.
- **For apps.** Turn a table's commands off (`keg.tenant_table(..., update => false, delete => false)`); say who an event is for and read your own with `keg.my_events` or `@keg/app`'s `db.events()`; see and put back failed jobs (`keg app jobs`, `keg app jobs retry`); give a check a database of its own (`db: true`) and its own instances of the services the app uses (`services: [query]`); a check that cannot be run has the verdict `error`.
- **Handing a piece of work files.** `keg work new --with <path>`, `keg work attach` and "Hand it to read" copy a file or folder once into the work's keeping, read only at `/keg/with` in its machine; `keg work allow-from` says which folders they may come from. `keg app client` brings an app's vendored `@keg/app` up to date.
- **Cleaning up.** `keg cleanup` shows what is on the node's disk and what can be freed, and `--apply` frees it. The node keeps the newest 5 builds of each service and removes the rest by itself. A Storage page in the console and the Mac app. A disk 85% full is said; from 95% a build or a pull is refused before it writes.
- **For coding agents.** The Keg skill is built in (`keg skill`, `keg skill install`), with `keg whoami` and `keg backing` for what a project needs beside it.

## Changed

- **The Mac's Linux machine is smaller and starts sooner**: 17 MB to download where it was 62, 50 MB in memory where it was 189, and its API answers 0.8 s after a start where it took 1.4.
- **Faster on a busy node.** On a Linux node with 200 containers, `keg ps` takes 3.8-10.4 ms where it took 14.7, the API's list of containers 2.1-3.7 ms where it took 12.9, a refresh of the Mac app costs the node 12-20 ms of processor where it cost 66, and the Mac no longer asks the node for its ports ten times a second.
- **A port of Keg's own that another program holds on the Mac is opened on the next free one**, so two nodes on one Mac no longer hand out each other's addresses.
- **Each environment of a service keeps its own port**, so a release approved into staging no longer takes the port of `local`.
- The node reaches a walled container from an address of its own on the walled bridge, which is never a container's.
- The console refuses a request another site's page sends.

## Upgrading from 0.10.0

- **Linux: restart the runtime agent.** After `keg update` and `sudo systemctl restart kegd`, a cleanup and checks with a database or services are refused until the agent that runs containers is started again: `sudo systemctl kill kegd`. Every running container stops; Keg's services and machines start again, other containers do not. **Mac:** Stop Keg, then Start Keg, in the app.
- **For a day after the upgrade the node removes nothing by itself**, and only says what it would; then it keeps the newest 5 builds of each service. To keep more, run `keg system keep builds 20` before then.
- **Finished work is never cleared by itself** unless you turn it on with `keg system keep works auto`.
- A work's machine that was running across the upgrade has no record of the container Keg made for it until it is started again; until then, clearing that work leaves its folder.
- Nothing of the assistant runs until you run `keg assistant setup`.

## Going back to 0.10.0

- Not supported once the assistant or its model gateway has been set up.
- Otherwise 0.10.0 leaves the new tables and columns it does not know as they are.

See [keg.rahultrikha.com](https://keg.rahultrikha.com) for more.
