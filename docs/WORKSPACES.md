# Workspaces, and the connector door

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

Fifteen tools, and no others:

| Tools | For |
|---|---|
| `workspace_new`, `workspace_list`, `workspace_show`, `workspace_stop`, `workspace_remove` | Its own workspaces, up to five at once |
| `files_write`, `files_read`, `files_list`, `files_search`, `files_patch` | Text files in a workspace's folder |
| `run`, `run_output` | A command, and the rest of what it printed |
| `run_start`, `run_status`, `run_stop` | A command that keeps going, such as a dev server |

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

## What is recorded

`keg events` shows each sign-in, approval and revocation, each workspace
made, started, stopped and removed, each file written (its path and size,
never its contents) and each command (who, where, its program, its exit,
and its words with what may be a secret hidden: best effort, not a
transcript). No token, code or key is ever recorded; the node keeps only
their hashes.

## Not built yet

Previews of what a workspace serves, git tools and `propose`, the SSH
door, and these pages in the Mac app.
