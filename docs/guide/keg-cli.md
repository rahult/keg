# keg CLI

Keg ships a companion command-line tool, installed in one click from
**Settings → Keg → Keg CLI** (no admin rights needed). It talks to the
running Keg app over its socket, so everything you see in the UI is what the
CLI reports.

## Commands

```sh
keg status                  # runtime + API server status
keg doctor                  # environment and install health check
keg version                 # CLI version

keg ps                      # list containers
keg images                  # list images
keg logs <name>             # stream a container's logs (-f to follow, -n tail)
keg exec <name> <cmd>       # run a command inside a container
keg attach <name>           # attach to the container's stdio

keg start <name>            # start a container
keg stop <name>             # stop a container
keg restart <name>          # stop + start
keg rm <name>               # delete a container

keg open [section]          # open the Keg app on a section
                            # (containers, images, logs, compose, kubernetes, …)
keg install / uninstall     # add or remove the `keg` binary from your PATH
```

## Deep links

`keg open` uses the `keg://` URL scheme, so it works no matter where the app
was installed from. Unknown sections land on Containers.

## Socket

The CLI finds Keg's socket automatically. Override it with an explicit path
when needed:

```sh
keg --socket /path/to/keg.sock ps
```
