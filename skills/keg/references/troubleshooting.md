# When something goes wrong

Read what Keg said: its errors say what to do. Then find the line here.

| Keg says | It means | Do |
|---|---|---|
| `an agent credential cannot call <METHOD> <path>` | That is a person's, not an agent's | Stop. Say what you tried and the command the person can run. Do not try another way in. |
| `forbidden`, 403 | The same | The same |
| `keg: command not found` | Keg is not installed here | Say so. Installing Keg is the person's. |
| `cannot reach kegd at ...` / `Is kegd running?` | The node is not running | On a Mac: `keg vm status`; starting it (`keg vm start`) is the person's unless they asked you to. On Linux: say so. |
| `outside the directories this node gives to agents` | Your machine's folder is not in the agent workspace | Say so; the person gives agents a folder (`keg vm start --agent-workspace <folder>` on a Mac, `kegd --agent-workspace` on Linux). |
| `there is already a machine named X` | You (or an earlier session) made it | `keg machine ls`: if its folder is yours, use it. |
| `an agent's machine has its folder and no other of the node's, and publishes no ports` | `-v` or `-p` on a machine | Leave them out; make it from the project's folder. |
| `the folder cannot be shared` (Mac) | Made from a home folder or a disk's top | Run it from the project's own folder. |
| `address already in use`, `port N ... belongs to <service>` | Another program or service holds the port | Use another port (`run.port` in keg.yaml, `--port`). Never stop what holds it unless you made it. |
| `port 7380 is in use by another program, so names are on 7381` | Another Keg or program holds the usual name port | Use the address Keg prints (`keg vm status`, what `keg up` says). |
| `waiting for a person: keg approve N --env E` | The release waits for approval | Stop and tell the person. Never approve. |
| `(the output is for a person to read: keg changes)` | A release failed; its detail is the person's | Say it failed, ask for `keg changes`; fix what you can see (the Dockerfile, the port, the health path). |
| `migration X was changed after it was applied` | A migration that ran was edited | Put the file back as it was; add a new migration. |
| `the new release exited with code 1` | The app crashed at start | It cannot reach what it needs (a backing service is not reachable from a service), or its start command fails: run it in a machine to see why. |
| `toomanyrequests`, `429`, `rate limit` while pulling | Docker Hub's limit for pulls | Wait and retry once; or use the same image from another registry (`mirror.gcr.io/library/postgres:16`, `public.ecr.aws/docker/library/postgres:16`). A node-wide mirror (`KEG_DOCKER_MIRROR` for kegd) is the person's to set. |
| `Bad message`, `I/O error` reading an image | A damaged copy | `keg pull --fresh <image>` (a person's rights); otherwise tell the person. |
| `no space left on device`, `the node's disk is 95% full`, a build refused for space | The node's disk is full | Stop. Remove only what you made (`keg machine rm`, `keg backing stop`). Freeing the rest is a person's: tell them what you saw; do not remove images, volumes or releases, search the node's files, or ask for more access. |
| `npm ERR! ... EAI_AGAIN`, no network in a machine | The node has no network out | Say so; nothing in Keg fixes it from inside. |
| A command in a machine stopped after ten minutes | The time limit | Start long ones in the background (`nohup ... &`) and read their log. |
| `keg skill show <name>`: no such file | | The names are `SKILL`, `machines`, `running`, `apps`, `release`, `troubleshooting`. |

## When you are refused

1. Do not retry the same thing, and do not try it another way (the
   person's socket, `sudo`, `docker`, the console, the Keg app, keystrokes).
2. Do what you may: a machine instead of a container, a backing service
   instead of `keg run`, a proposal instead of a deploy.
3. Tell the person, plainly: what you were doing, what was refused, and the
   exact command or click that is theirs.

## When something you were told about is not there

A file, a command, a flag, a table, an API the brief or a person named, and
it is not in the project or in `keg --help`: say so, with where you looked.
Do not write a stand-in and call it done, and do not search Keg's binary or
source for a hidden one.
