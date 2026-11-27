# Workspaces, and the connector door

Workspaces and the connector door are experimental: off until a person
turns them on, with `keg settings experimental on workspaces` and then
`on door` (and `on previews`, `on workspace-git`, `on ssh-door` for those).
See [EXPERIMENTAL.md](EXPERIMENTAL.md).

A workspace is a lasting Linux machine on your own server, for an agent
in a chat to build and run code in. You add your Keg node to the Claude
or ChatGPT app, or to Grok or Claude Code, as a connector; the agent then
makes a workspace, writes files in it, runs commands and reads what they
print. Nothing else can reach it, and it can reach nothing of yours.

This is for one person, the owner of the node. There are no accounts.

## What a workspace is

- A container of its own, run as an ordinary user (not root) with no
  capability, with memory, processes and CPU held to limits.
- A folder, `/work`, of a fixed size, that is **kept** when the workspace
  stops. Everything outside `/work` goes at each stop: install tools under
  `/work`, or install them again.
- It reaches the public internet (to fetch packages) and nothing private:
  not the server, not another workspace, not your network.
- It stops by itself after thirty idle minutes and starts again at the
  next call. A command left running (`run_start`) keeps it up, for two
  hours unless you say otherwise.

`keg workspace ls|show|new|stop|start|rm|limits|share` are yours as the
node's person, and show every workspace whoever made it.

## Setting it up

The connector door is served by the node's public front door, so the node
must have a public name. Claude connects to port 443 and no other.

1. **Two names that point at the server.** The node's public name, say
   `apps.example.com`, which what you share is served under, and a name
   of its own for the door under it, say `keg.apps.example.com`. Give
   each an `A` (and `AAAA`) record to the server. The door is never at
   the public name itself, and nothing is shared at the door's name: a
   page served under a name must not be able to reach a cookie of the
   door's.
2. **Open ports 443 and 80 to the world**, and nothing else for this.
   Port 80 is only for the certificate authority's check and to send
   browsers on to HTTPS. Keep the node's API port and every other port
   shut.
3. **Start the node with its public name:**

   ```
   kegd --public-domain apps.example.com --public-tls 0.0.0.0:443 --public-http 0.0.0.0:80
   ```

   The certificate is got from Let's Encrypt the first time the name is
   used, and renewed.
4. **Name the door**, by its own name under the node's:

   ```
   keg access name keg.apps.example.com
   keg access door
   ```

   `keg access door` prints the address to type into an app:
   `https://keg.apps.example.com/mcp`.

## Setting up a server, from nothing

The four steps above, and everything around them, as one command that
looks and says: `keg setup server`. This is the whole road, from a
fresh Ubuntu or Debian server you are root on and a domain you own.

1. **DNS.** Give the server's public address to a name and to every
   name under it: an `A` record for `keg.example.com` and a wildcard
   record for `*.keg.example.com` (and `AAAA` if the server has IPv6).
   The node's public name is `keg.example.com`; the connector door
   takes `mcp.keg.example.com`, and every app you share is a name under
   it too. A wildcard record covers all of them.

   Previews (optional) need **a second domain of your own** that shares
   no parent with `keg.example.com`: not `pv.keg.example.com`, and not
   `keg-previews.example.com` either, but say `keg-previews.example.net`,
   with a wildcard record `*.keg-previews.example.net` for the same
   address. A preview is `web--site.keg-previews.example.net`. A
   preview's page is a workspace's, whoever wrote it; under the node's
   own name it could set cookies for the door and every shared app, and
   its requests to them would count as the same site. Some DNS
   providers' wildcards cover one level only: `keg setup server` tries a
   preview's own name and says.
2. **Install Keg** on the server:

   ```
   sudo Scripts/install-linux.sh
   ```

   It installs `keg`, `kegd`, `keg-agent` and `keg-sshd`, and a systemd
   unit of Keg's own, `kegd.service`.
3. **Run the checklist**, as root, on the server itself:

   ```
   sudo keg setup server --domain keg.example.com
   ```

   It prints a line for each thing it looked at, each with a name that
   never changes, a state (`ok`, `to do`, `cannot tell` or `wrong`) and
   one sentence. Where something is Keg's own to change, it shows the
   exact change and asks before making it:

   | It may do, each asked first | What that is |
   |---|---|
   | Write `/etc/systemd/system/kegd.service.d/10-keg-public.conf` and restart `kegd` | The node's public name, added to Keg's own unit's start line. What runs keeps running. Removing the file and restarting puts it back. |
   | `keg access name mcp.keg.example.com` | The connector door's name (`--door` for another). |
   | `keg access previews keg-previews.example.net` | Where previews are answered: only with `--previews keg-previews.example.net`, or the domain you type when it asks. Left off otherwise; never made up from the node's name. |
   | `keg pull` of the image a workspace is made from | So that the first workspace does not wait for it. |
   | `useradd --system --no-create-home --shell /usr/sbin/nologin keg-sshd` | Only where the SSH door is on: a user of its own for the door's helper. The one thing made outside Keg's folders. |

   `--yes` does each without asking, still showing it. `--check` looks
   only, changes nothing, and ends with 1 while anything is left to do
   or wrong, for a script. `--json` prints the checklist for a program.

   It never edits the server's firewall, never touches a unit that is
   not Keg's, and never stops what holds a port: it says what holds it.
4. **Open the firewall** yourself, for what the checklist names and
   nothing else. With `ufw`:

   ```
   sudo ufw allow 443/tcp && sudo ufw allow 80/tcp
   sudo ufw allow 2222/tcp     # only if you turn the SSH door on
   ```

5. **Run it again** until every line is `ok` or `cannot tell`. A
   certificate is asked for as soon as the door has a name that leads
   here; it takes a minute. The last lines try the door from the node
   as an app would: its discovery page over TLS by name, with a
   certificate that verifies; `/mcp` refusing a caller with no token and
   saying where to sign in; anything else an empty 404.
6. **Let an app in**, as the next section says: `keg access open`, add
   `https://mcp.keg.example.com/mcp` in the app, and approve the code
   it shows.
7. **To shut it all:** `keg access close` ends new sign-ins (the door
   is shut to them unless you opened it, for ten minutes at a time);
   `keg access revoke NAME` ends one app or key at once, with what it
   had running; `keg access ssh off` ends the SSH door. Removing the
   firewall rules shuts the server to the world whatever Keg does.

The lines, by name:

| Line | What it looks at |
|---|---|
| `node.public-domain` | Whether the node was started with a public name. |
| `dns.domain`, `dns.door`, `dns.previews` | Whether each name leads to this server. Behind something that passes connections on, the server has only private addresses and says it cannot tell. |
| `ports.https`, `ports.http`, `ports.ssh` | That Keg listens there and nothing else does; what holds the port otherwise. |
| `firewall.open` | Never read: the ports to open, said. |
| `firewall.shut` | What of Keg's, or a database, a Kubernetes API or a Docker API, listens on an address other machines can reach. |
| `certificate.authority`, `certificate.door` | The account with the certificate authority, and the door's certificate. |
| `door.name`, `door.previews` | The names of the connector door and of previews. Previews off is fine; previews asked for under a domain that shares a parent with the node's public name are wrong; previews turned off as the node started (they were under its name) are to do, with why. `dns.previews` is looked at only once previews have a domain. |
| `workspace.image` | That the image a workspace is made from is here, held to its contents. |
| `ssh.door`, `ssh.user` | The SSH door, off unless you turned it on, and its helper's user. |
| `selftest.discovery`, `selftest.mcp`, `selftest.elsewhere` | The door, tried from the node as an app would try it. |

The console's Access page shows the same checklist, read only, on a
Linux node whose door has no name yet.

### What is open to the internet, and what is not

| | Open to the world | Why |
|---|---|---|
| TCP 443 | Yes | The connector door, previews, and what you share: HTTPS by name. Everything not a door's own path is an empty 404. |
| TCP 80 | Yes | The certificate authority's check, and sending browsers on to HTTPS. Nothing is served on it. |
| TCP 2222 (or the port you set) | Only if you turn the SSH door on | `ssh` into a workspace, by a key you added. No login to the server. |
| The node's API (its socket; `--listen` if you gave it) | No | Everything a person can do. `--listen` is for a network you trust, never the internet. |
| The door apps on this node reach their model at | No | On the node and its own bridge alone. |
| The model gateway, and every app's Postgres | No | Containers on the node's own network. |
| The Kubernetes API (6443) | No | On the node's loopback; reach it through SSH to the server. |
| The Docker-compatible socket | No | A file on the server. |
| The names router (127.0.0.1:7380 and :7443) | No | For this server alone. |
| A workspace | Never directly | Reached only through Keg's doors; it reaches the public internet and nothing of the server. |

`keg setup server` checks the "No" rows from the node's own side: it
reads what listens on the server and says, as `wrong`, anything of
these that listens on an address other machines can reach. Whether the
firewall lets the world through to it, only a look from outside tells.

## Letting an app in

The door is **shut to new sign-ins** until you open it, and shuts again
by itself after ten minutes. Apps you have already let in go on working
whether it is open or not. To anyone else the door looks the same open
or shut, short of a sign-in that would wait for you: an app may register
either way (that lets nobody in), and a sign-in begins only while it is
open. Each sign-in has a page of its own, and a page shows only its own
code; at most three sign-ins wait from one network.

**Apps sign in by registering.** Claude, ChatGPT, Claude Code and Grok
each register themselves with the door when they connect. Some of them
can instead name themselves by the address of a document (a "client
document") that the door would fetch from claude.ai or chatgpt.com.
That is **off** unless you turn it on (`keg access door
--client-documents on`): with it off, the node never fetches an address
a stranger chose, and every app still signs in by registering. With it
on, documents are fetched within tight limits, and only the addresses
the apps' own documentation names have places kept for them.

1. `keg access open`
2. Add the connector in the app (below). The app sends your browser to a
   page of the node's that shows a six-digit **code** and waits. The
   page asks for nothing: there is no password to type, and nothing on it
   to press.
3. Let that code in from a place you already trust:

   ```
   keg access approve 482193 --name "Claude on my phone"
   ```

   or in the console under Needs you. The page then goes on by itself.
4. `keg access close` if you are done before the ten minutes are up.

Read what `keg needs` says before you approve. It names the **host the
app asks to be sent back to**, and what the app says it is. The name is
only what the app says; the host is where whoever signs in is sent. Keg
knows the hosts Claude and ChatGPT use. For any other host it says so in
capitals, and the approval needs a second yes:

```
keg access approve 482193 --unknown-redirect
```

Say that only if the host is the app's own. Grok's is not documented by
xAI, so expect to be asked this the first time you add Grok; read the
host it shows.

### When more than one waits

While the door is open anyone who can reach it can ask, so more than one
may wait at once. Each has a code of its own, and only the app you began
with shows you yours.

```
keg access ls --waiting    # each: its code, how long ago it asked, from which address,
                           # where it asks to be sent back to, what it says it is
keg access dismiss 771024  # turn one away; its page says it was not let in
```

`keg access approve` prints which one it let in: the address it asked
from, when, and what it said it was. A code that is not one that waits
is told how many wait and never which codes they wait with; five wrong
answers end those that wait, and each app then asks again. Turning one
away with a code that does not wait ends nothing.

### The same app, signing in again

An app that signs in again (a new phone, a reinstall, a sign-in that
ended) is, unless you say otherwise, a **new identity** with no
workspaces. To give it the workspaces an identity already has, let it in
**as** that identity:

```
keg access approve 482193 --as "Claude on my phone"
```

Keg first says what that does and does nothing: which connector it is,
which workspaces it will have, and that every sign-in the identity has
now ends at once, so that one app holds it and not two. Say yes to that
with `--yes`:

```
keg access approve 482193 --as "Claude on my phone" --yes
```

The identity keeps its name, its workspaces and what runs in them. Only
a connector that is still let in can be joined: not a key, and not one
you revoked.

A host Keg does not know that you said yes to (`--unknown-redirect`) is
kept for that identity and that client alone. Its later sign-ins, let in
**as** it, need the code and no second yes; a new identity, or another
client naming the same host, is asked again. `keg access show NAME` lists
what an identity keeps, and `keg access forget-redirect NAME HOST` takes
one back.

### Claude (web, desktop, then the phone)

On claude.ai or Claude Desktop: Customize > Connectors > Add > Custom >
Web. Give it a name and the address `https://keg.apps.example.com/mcp`, and
sign in when asked. A connector added there is used from the iOS and
Android apps too. Any plan; the Free plan has one custom connector.

### Claude Code

```
claude mcp add --transport http keg https://keg.apps.example.com/mcp
```

then `/mcp` in a session (or `claude mcp login keg`); a browser opens on
the page with the code.

### ChatGPT

On chatgpt.com (the web only): Plugins > + > "Add custom MCP server";
give it a name, the address and OAuth. OpenAI's help centre gives tools
that change things only to Business and Enterprise/Edu workspaces; on
other plans ChatGPT may offer the read tools alone. ChatGPT asks you
before each call of a tool that changes something.

### Grok

At grok.com/connectors: New Connector > Custom, the address, then the
sign-in. Expect the second yes described above.

### An API, or a script

Grok's and OpenAI's APIs run no sign-in: they are handed a token. Make
one by hand; it is shown once and is good for ninety days unless you say:

```
keg access token "Grok through its API" --days 30
```

Pass it as the `authorization` of the API's `mcp` tool, with the door's
address as `server_url`.

## Seeing and ending what you let in

```
keg access ls                     # who is let in, what each has, when each was last used
keg access show "Claude on my phone"
keg access revoke "Claude on my phone"
keg workspace show site           # and what was lately run in it
```

Revoking ends that identity's tokens at once, ends what it is running,
and stops its workspaces. Their folders are kept, yours to remove with
`keg workspace rm`. A client that registered itself is forgotten when the
last identity it let in is revoked, and those that let no one in are
forgotten when the door closes, with the codes that waited.

### In the console

`keg ui` has two pages for this, under **Apps you let in**.

**Access** shows the door (its address, whether it takes sign-ins, with
Open for ten minutes and Shut now), those that wait, and everyone let in
with what each has: its workspaces, how many run, commands left running,
a token made by hand and how long it is good for, and any host you let it
keep. From there you rename, revoke, make a token by hand (shown once),
and take a kept host back.

To let a waiting connector in you **type the code its page shows**. The
console lists who waits, from which address, and what each says it is,
and never shows a code or fills one in: that the code you read in the app
matches is how you know the request is the one you began. A code that is
not this request's is refused in the page and is not a wrong answer.
Letting it in as an identity there already is shows what that does first,
and is done on a second press. Needs you shows the same requests.

**Workspaces** lists every workspace with its owner, whether it runs, how
much its folder holds and when it was last used; one opens to its image,
limits, what is left running, and what was lately run in it: the
program, its words with what may be a secret hidden, who ran it and how
it ended. What a command printed is never kept, so it is not shown. You
stop, start and remove a workspace there, change its limits, and set the
limits of those made from now on. How much of its folder a workspace has
used is not shown yet.

## What an agent at the door can do

Thirty tools, and no others:

| Tools | For |
|---|---|
| `workspace_new`, `workspace_list`, `workspace_show`, `workspace_stop`, `workspace_remove` | Its own workspaces, up to five at once |
| `files_write`, `files_read`, `files_list`, `files_search`, `files_patch` | Text files in a workspace's folder |
| `run`, `run_output` | A command, and the rest of what it printed |
| `run_start`, `run_status`, `run_stop` | A command that keeps going, such as a dev server |
| `preview_open`, `preview_list`, `preview_close` | A private address for a port a server in the workspace listens on |
| `preview_fetch` | What that port answers, read by the node: the status, a few headers and the start of the body |
| `preview_ask_public` | Asking you to make a preview public; asking changes nothing |
| `git_status`, `git_diff`, `git_log`, `git_commit`, `git_branch` | Version control in the workspace's repository |
| `git_push`, `git_fetch`, `git_pull` | A repository elsewhere, only one you gave the workspace, with the key you granted for it |
| `propose` | A release built from the workspace's last commit, for the one service you tied it to; it waits for you wherever an agent's release does |
| `needs` | What it asked for that waits for you: its proposals, its askings for a public preview |

A reply is at most 30,000 characters and says how to read the rest. `run`
waits thirty seconds for a command (up to 120 if asked); one that takes
longer is not stopped: the reply names it, and `run_status` follows it.

## What it cannot do

- Anything that is a person's: approving or confirming, the vault,
  grants, installing a service, limits, letting another app in. None of
  it is reachable from the door at all.
- See, start, stop or learn the name of a workspace that is not its own.
  Another's is refused in the words a missing one is.
- Choose a workspace's image, or change its limits.
- Reach the server, another workspace or a private network from inside a
  workspace.

What it **can** do, and you should know: a workspace reaches the public
internet and `run` runs anything, so whatever is in a workspace can be
sent anywhere. Keep nothing in a workspace that must not leave it. And
what a tool returns (a file, a command's output, a page it fetched) is
read by the model, which may hold your other connectors too; treat an
app's "always allow" as convenience, not as safety. Keg's rules above
hold with every call approved.

## Limits

- Each identity: five workspaces at once.
- Each workspace: `keg workspace limits` shows and sets the node's
  defaults (folder size, memory, processes, idle minutes, a command's
  longest time).
- `keg access keep MINUTES`: how long a command left running keeps its
  workspace from being stopped for being idle.
- At the door, before anyone is let in: a few connections and 120
  requests a minute for each address, a request of at most 256 KiB sent
  within twenty seconds, five registrations and five sign-in attempts for
  each address in ten minutes.

## Git, a repository elsewhere, and its key

An agent commits in its workspace with `git_commit` (and can run any
`git` command with `run`: the repository is its own). A commit is by
whoever the repository says; where it says nobody, by the connector as
you named it, at `<workspace>@workspace.keg.invalid`, an address that is
nobody's. What it gives a git tool is checked before anything runs: a
branch's name is letters, digits and `. _ - /`; a path is inside the
folder; nothing may begin with `-`. Anything else is refused, and an
agent that needs more uses `run`.

A workspace pushes **nowhere** until you give it a repository and a key:

```
keg vault set shop/deploy < deploy-key          # a private key, or a token for https
keg workspace remote site add origin git@github.com:me/site.git --key shop/deploy
```

For an `ssh` address the second command adds nothing the first time: it
asks the host for its key from inside the workspace and prints the
fingerprints. Compare one with what the host's own keeper publishes (for
GitHub, GitLab and the like, their documentation), not with what the
command printed, and run it again with `--host-key SHA256:…` (or give
the key whole, `--host-key 'ssh-ed25519 AAAA…'`, and the host is asked
nothing). From then on a push or fetch accepts that host only with that
key. `https://` takes a token and needs no host key.

What you should know before you grant one:

- **A workspace granted a key can use that key for as long as it is
  granted.** The node hands the key to the one `git` command that needs
  it, in a file that exists for that command and is removed after; it is
  in no event, no reply, no record and no variable. That command reads
  none of the settings the workspace wrote (its repository's, its
  user's): it runs in a repository of the node's own making, goes to the
  address you gave and no other, and answers a question for a name and
  password only when the question is about that host. But whatever runs
  in the workspace runs as the same user, and could read the key while
  a push is under way. Treat the grant as giving the workspace the key.
- So give it a key that opens one repository and nothing else: a
  **deploy key**, or a token scoped to that repository.
- A push sends one branch to the same name and overwrites nothing;
  `--allow-force` on `remote add` lets pushes from that workspace
  overwrite, if you mean it. Tags are not pushed.
- `keg workspace remote site rm origin` takes the repository and the
  grant away at once; a push under way is ended by stopping the
  workspace. Revoking the connector ends it too. `keg vault ls` shows
  the grant: "the workspace site, for its repository at github.com".

`keg workspace new site --from git@github.com:me/site.git --key
shop/deploy --host-key SHA256:…` makes a workspace from a repository
that is not public, with that repository as its `origin`.

## Proposing a release from a workspace

`keg workspace project site shop` says the one service the workspace
`site` may release: the `service:` of the `keg.yaml` at the top of its
repository must be `shop`, and a commit for any other service is
refused. A workspace tied to nothing proposes nothing.

`propose` then takes the workspace's **last commit** (what is not
committed is not in it, and the reply says so), which the node reads out
itself: git packs the commit in the workspace, the node takes that one
file, lays it out where only the node can touch it, and builds from
there. Nothing is built from outside the commit, through a link or
otherwise. The release is an **agent's**, by Keg's existing rules:

- it runs by itself only where the environment applies an agent's
  release by itself (`local`, unless you changed that);
- anywhere else it is a change set that waits for you, in Needs you,
  `keg needs` and `keg changes`, marked "proposed from the workspace
  site by the connector Claude on my phone (commit 1a2b3c4d5e6f)";
- it is handed no vault entry without your approval: an agent's release
  that needs a secret waits for you even where others apply by
  themselves.

The agent's `needs` lists what it asked for that still waits. It cannot
approve anything.

## What is recorded

`keg events` shows each sign-in, approval and revocation, each workspace
made, started, stopped and removed, each file written (its path and size,
never its contents), each commit, push, fetch and pull made through the
git tools (to which remote, which branch, how it ended; never the key),
each remote given and taken away, each release proposed, each session at the SSH door
(whose key, which workspace, from where, for how long; never what was
typed or printed) and each port forwarded through one, and each command (who, where, its program, its exit,
and its words with what may be a secret hidden: best effort, not a
transcript). No token, code or key is ever recorded; the node keeps only
their hashes.

## Previews: looking at what a workspace serves

A preview gives one port of a workspace a private https address of its
own, so that you can open what an agent built in your browser. The
workspace's wall is not opened: the node connects to the workspace, and
the workspace still reaches nothing of the node.

Set it up once. Previews are answered under a domain of your own that
shares no parent with the node's public name. Beside a node at
`keg.example.com`:

```
keg access previews keg-previews.example.net
```

In your DNS, every name under it must lead to the node: a wildcard
record, `*.keg-previews.example.net`. Each preview gets a certificate of
its own as it is opened. Keg refuses a domain that is the node's public
name, under it, over it, or beside it under the same parent
(`pv.keg.example.com`, `keg-previews.example.com`): a preview's page
could otherwise set a cookie for the node's name, which the connector
door and every shared app are sent, and its requests to them would be
same-site, so their `SameSite` cookies would go with them. Keg takes a
name's site as its last two parts, or three under a country's suffix of
two (`example.co.uk`); it does not carry the Public Suffix List, so a
domain under a private suffix such as `duckdns.org` is refused beside
another under it. `keg access previews off` leaves previews off.

A node set up before this, with previews under its own name, has them
turned off as it starts: every preview is closed, and the log, `keg
access`, `keg access previews` and `keg setup server` say why and what
to do, until you give previews a domain of their own or turn them off.

Every preview is under the one previews domain, so one preview's page is
same-site with another's. A preview answers a request another
preview's page sends only when it is a person following a link; the
browser says which (`Sec-Fetch-Site`). The connector door, for its
part, refuses what a page of another site posts to it.

A preview's address is `https://<name>--<workspace>.keg-previews.example.net`.
You open one with `keg workspace preview site 3000` (or `--name web`), in
the console, or the agent does with `preview_open`. The server in the
workspace must listen on `0.0.0.0`, not only on `localhost`.

**A preview is private.** Open its address and you are told so. Ask to be
let in and the page shows a six-digit code and waits. Say the code
somewhere you already trust:

```
keg access approve 305518 --name "my phone"
```

or in the console, under Needs you or Access, where you type the code
the browser's page shows. That browser is then let in to that one
preview, for seven days (`keg access previews --days N` changes it), and
to nothing else: the cookie it is given is good at that one name. Let in
only a browser that is yours and that you opened the address in yourself,
just now: the list says the address each one asked from. `keg access ls`
lists browsers with everything else let in, and `keg access revoke NAME`
ends one at once, with what it has open.

A browser that was not let in never reaches the workspace: the node
answers it. What does go on to the workspace has Keg's own cookies and
any `Authorization` taken out, and what the workspace's server sends
back can set no cookie of Keg's names and none for a wider name than the
preview's own. An answer the node cannot read as a browser would is not
passed on at all.

A stopped workspace answers "asleep" and is not started by a visit,
unless you said a browser may start it (`keg workspace preview site 3000
--wake`). A preview keeps its workspace from being stopped for being idle
only while requests you let in arrive, and for no longer than a running
command would (`keg access keep`).

**Making one public is yours alone.** `keg workspace publish site 3000
--for 2h` makes that one address answer anyone, for an hour unless you
say, seven days at most; `keg workspace unpublish site 3000` ends it now.
An agent can ask (`preview_ask_public`): you are told under Needs you,
and nothing is public until you run the command.

**What the agent sees.** It cannot open the address. `preview_fetch`
has the node fetch one path of that port, with GET or HEAD, and returns
the status, a few headers and the first 30,000 characters, marked as
data. It asks that port of that workspace and nowhere else, and follows
no redirect.

`keg workspace previews` lists every preview and every browser let in;
`keg workspace unpreview site 3000` closes one.

## The SSH door: a terminal in a workspace

The connector door is for an app. The SSH door is for you, or for an
agent that has a terminal: `ssh` lands in a workspace, as its user, in
its folder. It is off until you turn it on.

```
keg access ssh on                       # port 2222, unless you say another
keg access ssh                          # how it is, its own key, what is open
keg access add-key laptop < ~/.ssh/id_ed25519.pub
ssh -p 2222 site@keg.example.com        # a shell in the workspace `site`
ssh -p 2222 new@keg.example.com         # makes a workspace, and lands in it
ssh -p 2222 site@keg.example.com npm test
scp -O -P 2222 notes.txt site@keg.example.com:
sftp -P 2222 site@keg.example.com       # where the workspace's image has sftp-server
ssh -p 2222 -L 3000:localhost:3000 site@keg.example.com
```

`keg access ssh port 2200` moves it and `keg access ssh off` shuts it,
ending every session. Open the port in your server's firewall; port 22
stays the server's own, and Keg never offers a login to the server.

### Whose key lands where

A key is an identity, as a connector is: it reaches the workspaces that
identity made (with `new@`) or that you shared with it (`keg workspace
share site --with laptop`), and no others. The name before the `@` is
the workspace. A workspace that is another identity's, a name nothing
has, `root`: each is refused in the same words and after the same wait
as a key nobody added, so the door says nothing of what is on the node.

Only keys are taken: ed25519 and ecdsa. There are no passwords, no
certificates, and nothing to type but the command. Give `add-key` the
`.pub` file; a private key is refused and kept nowhere.

### Pin the door's key

`keg access ssh` prints the door's own key and the line for
`~/.ssh/known_hosts`. Add it before you first connect, so that `ssh`
never asks you to trust a key on sight:

```
[keg.example.com]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI…
```

The key is the node's, made the first time the door is turned on, and
stays the same as the node starts again and is updated. In
`~/.ssh/config`:

```
Host site
  HostName keg.example.com
  Port 2222
  User site
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ForwardAgent no
```

### What is carried, and what is refused

| Asked for | Answer |
|---|---|
| A shell, a command, `scp -O`, `sftp` | In the workspace, as its user. `sftp` runs the image's own `sftp-server` inside the workspace; an image without one says so. |
| `-L` to `localhost` or the workspace's name | To that workspace's own port. |
| `-L` to anything else | Refused: not the server, not another workspace, not an address of the server's network, by any name. |
| `-R`, `-D` to elsewhere, a socket (`-L /path`) | Refused: the door opens nothing on the server and carries nothing back to your computer. |
| Your agent (`-A`), your display (`-X`) | Refused. A workspace runs an agent's code; it is never handed your keys or your screen. |
| A tunnel (`-w`), compression, a password | Refused. |

Of what your terminal says of itself, `TERM`, `LANG`, `LC_*` and
`COLORTERM` reach the session, and nothing else of your environment.

### What ends a session

Revoking the key (`keg access revoke laptop`), stopping or removing the
workspace, taking a shared workspace back, turning the door off, or
`keg access ssh end SESSION`: each closes it at once, with what was
running in it. A session also ends after twelve hours, and one on which
nothing passes after thirty minutes. A key has eight sessions at most,
and so does a workspace; a session keeps its workspace from being
stopped for being idle.

### How it is built, and what that means

The SSH protocol is not spoken by the node. A small program of Keg's,
`keg-sshd`, speaks it: the node starts it with no rights at all (its own
user, no file or folder of the node's, a network of its own with nothing
in it) and hands it the door's port, already open. All it can do is ask
the node three things: whose key is this and is that name one of its
workspaces, start this in that session, connect to that session's
workspace. The node decides each, and every limit.

So a fault in the code that reads strangers' packets is a fault in a
program that can only ask. One thing it is believed about: that a client
proved it holds the key it names. A `keg-sshd` that was taken over could
therefore reach what the keys you added reach, their workspaces, and
nothing of the server's beyond what any user of the server sees, such
as the list of running programs. Keg puts no secret in a program's
command line: a workspace's repository key or token is handed to the
command that uses it in its environment, which only root and that
command's own user can read. If that is more than you want exposed, leave the
door off and use the connector door, or reach port 2222 only through
your own VPN.

## Giving a workspace the model

A workspace reaches nothing of the node's until you give it the model,
with a ceiling a day of its own:

```
keg workspace model site on --usd-per-day 2
keg workspace model site            # what it has
keg workspace model site off
```

From its next start (a running workspace is stopped, and the next command
starts it), each new command in it, at the connector door or the SSH door,
is given:

| Variable | Value |
|---|---|
| `OPENAI_BASE_URL` | the node's door to the model, `/v1` |
| `ANTHROPIC_BASE_URL` | the same door |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | the workspace's own token |
| `KEG_DOOR_URL`, `KEG_DOOR_TOKEN` | the same, for `@keg/app` |

So OpenAI's and Anthropic's SDKs, and the agent frameworks on them, ask
the model with nothing set by hand. A variable a command is given by its
caller is its own and wins. The door answers Chat Completions, Responses,
Messages and `GET /v1/models`, streamed or whole, for the models offered to
apps (`keg assistant model --apps`), exactly as an app's door does
(`docs/ASSISTANT.md`). What the workspace asks is spent as
`workspace:NAME`, held to its ceiling and to the node's; `keg assistant
usage` shows it, and `keg assistant limits workspace:NAME` changes it.

**What it reaches.** Its wall allows one address and port of the node's
besides the internet: the door, on the walled bridge's gateway. Nothing
else of the node's (not the next port, not the apps' door, not another
address) and nothing of a private network. The door lets in only a
workspace given the model, from the address the node gave it, with its
own token; a workspace not given it is closed on before anything is read.
The provider's key never reaches the workspace.

**What ends it.** `off` stops the workspace; it starts again with no door
in its wall and no token. A stop makes its token one the door refuses: the
next start gives a new one, which only the commands started after it have.
Its owner's identity revoked stops it, ends its token at once and takes
the grant back. Removed, its grant, its token and its limit go with it: a
grant is of that very workspace and its owner, so a workspace made later
with the same name, by anyone, has no way to the model until a person
gives it one. An
identity it was only shared with that is revoked, or that it is no longer
shared with, stops it and makes its token new: what that identity left
running in it could otherwise read the token of the owner's next command.

## Not built yet

These pages in the Mac app. At the SSH door: RSA keys, signals sent by
the client, and `sftp` for an image with no `sftp-server` of its own.
A push of tags and a merge
by `git_pull` where two branches have parted (use `run`) are not built either.
