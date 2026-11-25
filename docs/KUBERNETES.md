# Kubernetes on Keg

`keg k8s start` gives you a Kubernetes cluster on your own node: one node of
[k3s](https://k3s.io) in a container called `keg-k8s`, with everything the
cluster holds kept in a volume of the same name. This guide is about what
comes after: connecting to it, running something, reaching what runs,
bringing your own images in, and what happens to it over time.

On a Mac the node is Keg's Linux VM; on a Linux server it is the server.
Everything here was tried on a Mac.

## Start it

```sh
keg k8s start
```

The first start downloads the k3s image (70 MB); after that the cluster is
ready in a few seconds. It prints where the API is and what to do next, and
writes the settings `kubectl` needs to `~/.keg/k8s/kubeconfig.yaml`.

`keg k8s info` prints the same details again at any time, and
`keg k8s info --json` gives them to tools:

```
Kubernetes: running
API:          https://127.0.0.1:6443
kubeconfig:   /Users/you/.keg/k8s/kubeconfig.yaml
context:      keg (its cluster and user are called keg too)
connect:      export KUBECONFIG=/Users/you/.keg/k8s/kubeconfig.yaml
...
```

`keg k8s status` lists the node and every pod, and ends with the same
connect line.

## Connect

### With kubectl

```sh
export KUBECONFIG=~/.keg/k8s/kubeconfig.yaml
kubectl get nodes
```

The context, the cluster and the user in the file are all called `keg`.

The API is published on port 6443 when that port is free. If another
program already has 6443 on your computer (another cluster, say), Keg
publishes it on the next free port and the kubeconfig names that one;
`keg k8s start` says so, and `keg k8s info` always gives the address that
really leads to this cluster. Once it has moved, it stays on its new port
from one start to the next, so a copy of the kubeconfig keeps working.

### Beside your other clusters

Keg's file is written on its own and never merged into `~/.kube/config`.
To use both, name both:

```sh
KUBECONFIG=~/.kube/config:~/.keg/k8s/kubeconfig.yaml kubectl config get-contexts
KUBECONFIG=~/.kube/config:~/.keg/k8s/kubeconfig.yaml kubectl --context keg get nodes
```

With the two files in `KUBECONFIG`, the current context is the first file's;
`--context keg` picks this cluster for one command. `--kubeconfig
~/.keg/k8s/kubeconfig.yaml` works on any one command, too.

### The file is the key

The kubeconfig holds a client certificate for `system:admin`, in the group
`system:masters`: whoever has the file can do anything in the cluster. Keg
writes it readable by you alone (mode 0600). Do not commit it or paste it
anywhere. `keg k8s delete` removes it with the cluster.

### With no kubectl on your computer

`keg k8s kubectl ...` runs the kubectl inside the cluster's container:

```sh
keg k8s kubectl get pods -A
keg k8s kubectl -n keg-guide logs deployment/web --tail=20
keg k8s kubectl -n keg-guide exec deployment/web -- nginx -v
keg k8s kubectl -n keg-guide apply -f app.yaml
keg k8s kubectl -n keg-guide apply -f - < app.yaml
keg k8s kubectl -n keg-guide exec -it deployment/web -- sh
keg k8s kubectl -n keg-guide logs -f deployment/web
```

What works:

- One-off commands (`get`, `describe`, `logs`, `exec ... -- cmd`, `scale`,
  `delete`): run to their end, their output printed then.
- A manifest on your computer: `-f app.yaml` sends the file (kubectl in the
  container could not see it), and `-f -` reads what you pipe in.
- At a terminal, the command is connected to it as it runs: an interactive
  shell (`exec -it ... -- sh`), following output (`logs -f`), and Ctrl-C to
  end it.

What does not:

- `port-forward` and `proxy` are refused: run in the container, they would
  listen where nothing on your computer reaches them. Install kubectl for
  these; [Reach what runs](#reach-what-runs) has other ways.
- Several files (`-f a.yaml -f b.yaml`) or a folder (`-f dir/`) are not sent;
  pipe them in instead (`cat a.yaml b.yaml | keg k8s kubectl -n keg-guide apply -f -`).
- Run from a script rather than a terminal, a command that does not end by
  itself (`logs -f`, `get -w`) prints nothing until it is stopped, and goes
  on in the cluster's container after you stop it. Give it an end
  (`--tail`, `--since`, no `-w`) instead.

### Other tools

Anything that reads a kubeconfig works the same way, given the file:

- **Helm**: `helm list -A` with `KUBECONFIG` set as above; `helm install`
  and `helm uninstall` were tried with a chart made by `helm create`.
- **k9s**: `k9s --kubeconfig ~/.keg/k8s/kubeconfig.yaml` (not tried).
- **Lens**, **Headlamp**: add the file, or a folder holding it, as a
  kubeconfig in their settings (not tried).

## From nothing to a page in your browser

```sh
keg k8s start
export KUBECONFIG=~/.keg/k8s/kubeconfig.yaml
kubectl create namespace keg-guide
kubectl -n keg-guide create deployment web --image=nginx:1.27-alpine --port=80
kubectl -n keg-guide rollout status deployment/web
kubectl -n keg-guide expose deployment web --port=80
kubectl -n keg-guide port-forward service/web 8080:80
```

Open <http://localhost:8080>: nginx's welcome page. Ctrl-C ends the
`port-forward`. If 8080 is taken on your computer (`bind: address already
in use`), use another port on the left: `8081:80`.

Your own image, built by Keg, reached without a `port-forward`:

```sh
keg build -t hello:1 .                      # a Dockerfile serving on 8080
keg k8s load hello:1
kubectl -n keg-guide create deployment hello --image=hello:1 --port=8080
kubectl -n keg-guide expose deployment hello --type=LoadBalancer --port=8088 --target-port=8080
keg k8s stop
keg k8s start --publish 8088
curl http://localhost:8088/
```

## Run things

The cluster is plain Kubernetes; what you know of kubectl applies.

```sh
kubectl create namespace keg-guide
kubectl -n keg-guide create deployment web --image=nginx:1.27-alpine --port=80
kubectl -n keg-guide apply -f app.yaml
kubectl -n keg-guide get pods,services
kubectl -n keg-guide describe pod -l app=web
kubectl -n keg-guide logs deployment/web --tail=20
kubectl -n keg-guide exec deployment/web -- nginx -v
kubectl -n keg-guide exec -it deployment/web -- sh
kubectl -n keg-guide scale deployment/web --replicas=3
kubectl -n keg-guide delete deployment web
kubectl delete namespace keg-guide
```

Images named without a registry (`nginx:1.27-alpine`) come from Docker Hub,
pulled by the cluster itself.

## Reach what runs

Only the cluster's API is published from its container, and the cluster
has no ingress (Traefik, which k3s usually brings, is turned off: ports 80
and 443 of the node are for Keg's own names). So a Service is not on your
computer by itself. These ways reach one:

| From | To | How |
|---|---|---|
| Your computer | a Service or a pod | `kubectl port-forward service/web 8080:80` (or `pod/NAME`, `deployment/NAME`), then `http://localhost:8080`. It goes through the API, so it works wherever kubectl does. Needs kubectl on your computer. |
| Your computer | a LoadBalancer Service | `keg k8s start --publish 8088` publishes port 8088 of the cluster's node; a Service of type LoadBalancer on port 8088 answers at `http://localhost:8088`. |
| Your computer | a NodePort Service | `--publish` the NodePort (`--publish 30080`): the same, at `localhost:30080`. NodePorts (30000–32767) are not published otherwise. |
| A container on Keg (`keg run`) | a published port | `http://127.0.0.1:8088`: such a container shares the node's network. |
| A container on Keg (`keg run`) | a LoadBalancer or NodePort Service | the address the Service shows as `EXTERNAL-IP` (the `keg-k8s` container's address, for example `10.88.143.41`), on the Service's port or its NodePort. This address changes each time the cluster is started from stopped; a published port does not. |
| A pod | another Service | its name: `http://web` in the same namespace, `http://web.keg-guide.svc.cluster.local` from anywhere in the cluster. |
| A pod | a port Keg publishes on the node (another app, a database) | `10.88.0.1:PORT`, the node's address on Keg's container network. |

About `--publish`:

- Ports are set when the cluster's container is made, which is when it is
  started from stopped: `keg k8s stop`, then `keg k8s start --publish 8088`
  (repeat `--publish` for more). Starting it again without `--publish`
  publishes none. Asked of a running cluster with other ports, it says so.
- A published port is on the node's loopback only, like the API: your
  computer reaches it (on a Mac through Keg's forwarder), other machines do
  not.

What does not work:

- A NodePort that is not `--publish`ed is not reachable from your computer,
  and neither is the `EXTERNAL-IP` of a LoadBalancer Service: both are
  addresses inside Keg's Linux VM.
- A Service's cluster address (`10.43.x.x`) is reachable only from inside
  the cluster.
- A Keg container does not find the cluster by name (`keg-k8s` does not
  resolve).

## Your own images

The cluster has its own image store, separate from Keg's. An image you
built with `keg build`, pulled with `keg pull` or loaded with `keg load` is
not in it, and a pod that names it fails with `ErrImagePull`: the cluster
looks for it in a registry. `keg k8s load` puts it there:

```sh
keg build -t hello:1 .
keg k8s load hello:1
```

```
docker.io/library/hello:1 is in the cluster (2 MB)
```

A pod then finds it by that name. Kubernetes looks in a registry first only
for an image tagged `latest` (or with no tag), unless told not to:

```yaml
    spec:
      containers:
        - name: app
          image: keg.local/app:latest
          imagePullPolicy: IfNotPresent     # or Never
```

Load it again after each build: the cluster keeps the copy it was given. A
loaded image takes room twice, once in Keg's store and once in the
cluster's, which is in the `keg-k8s` volume.

## Storage and life cycle

**Volumes.** The default StorageClass is `local-path`: a
PersistentVolumeClaim gets a folder under `/var/lib/rancher/k3s/storage` in
the cluster's container, which is in the `keg-k8s` volume. It outlives its
pods and a `keg k8s stop`.

**`keg k8s stop`** stops the container. Deployments, Services, volumes and
loaded images are kept; `keg k8s start` makes the container again from the
volume and the pods start again (each counts a restart). A bare pod with
`restartPolicy: Never` is left as `Unknown`. The address a LoadBalancer
Service shows changes.

**When the VM or the Mac restarts**, the cluster does not come back by
itself: on a Mac a restarted VM brings back deployed services, not
containers started by hand, and `keg-k8s` is one of those. `keg k8s start`
brings it back with everything in it. (Not tried here: it is what Keg does
with every container it did not deploy.)

**`keg update`** replaces the `keg` command; what runs is left running. The
k3s version is fixed by the `keg` release: this one runs
`rancher/k3s:v1.31.4-k3s1` (Kubernetes v1.31.4). A later release that names
a newer k3s uses it the next time the cluster is started from stopped, with
the same volume. (Not tried: no release has changed it yet.)

**`keg k8s delete`** removes the container, the volume and the kubeconfig:
everything in the cluster is gone. The k3s image stays in Keg's store;
`keg rmi rancher/k3s:v1.31.4-k3s1` removes it.

**What it takes.** Idle, with only its own pods: about 660 MB of memory,
around 2% of one processor and 105 processes (`keg stats`); 245 MB in its
volume, and the 70 MB image. Each image you load adds its size.

**Logs.** `keg logs keg-k8s` is k3s's own output: the place to look when it
does not start.

## Security, plainly

- **The cluster's container is privileged**: every capability and cgroups
  of its own, so that it can run containers. What runs in it can do to the
  node what root can. On a Mac the node is Keg's Linux VM, so that is root
  in the VM, which holds every container and volume Keg has; on a Linux
  server it is root on the server. Only a person can start it.
- **The kubeconfig is cluster-admin**, and with it anyone can run a
  privileged pod: holding the file is as good as root on the node. Keep it
  as you would an SSH key.
- **The API is published on the node's loopback only** (`127.0.0.1`, port
  6443 or the next free one). On a Mac, Keg's forwarder opens it on your
  Mac's loopback; other machines cannot reach it. On a Linux server, only
  programs on the server reach it; from elsewhere, use an SSH tunnel to the
  server's port 6443 (not tried).
- Containers on Keg do not see the kubeconfig unless a folder holding it is
  given to them.

## Coding agents

Every `keg k8s` command is a person's. On the agent's socket, Keg refuses
an agent `start`, `stop`, `delete`, `kubectl` and `load`, because each runs
something in the cluster's container; `info` tells an agent only what it
may read, without where the API is reached.

The cluster itself is not held to Keg's rules for agents: what an agent may
do there is whatever the kubeconfig it holds allows, and Keg's own
kubeconfig allows everything. An agent running on your computer as you can
read `~/.keg/k8s/kubeconfig.yaml`. If an agent should work in the cluster,
give it a kubeconfig of its own, with a Role limited to a namespace, made
with kubectl; do not hand it Keg's.

## Troubleshooting

- **`keg k8s start` says the cluster stopped as it started.** `keg logs
  keg-k8s` says why. With Keg 0.12.0 a start could fail with
  `cgroup ["kubepods"] has some missing controllers`, when Keg asked the
  cluster whether it was ready at the moment k3s was setting up its
  cgroups; this release waits for k3s to begin first. Run `keg k8s start`
  again.
- **kubectl says `Unable to connect to the server`.** The kubeconfig may
  name a port that leads somewhere else, which Keg 0.12.0 did when another
  program held 6443. Run `keg k8s
  stop` and `keg k8s start` to write it again, and compare with `keg k8s
  info`.
- **A pod is `ErrImagePull` or `ImagePullBackOff` on an image you built.**
  The cluster does not have it: `keg k8s load IMAGE`. If it is tagged
  `latest`, give it `imagePullPolicy: IfNotPresent`.
- **`ctr: wrong diff id calculated on extraction`.** That is an image
  built by Keg, written out by `keg save` of 0.12.0 or earlier: Keg's store
  names a built image's base layers in a way containerd refuses. This
  release's `keg save` and `keg k8s load` write it as containerd expects.
- **`port-forward` says `bind: address already in use`.** Something on your
  computer has that port; choose another (`8081:80`).
- **`keg k8s kubectl apply -f app.yaml` says the path does not exist.**
  Keg 0.12.0 passed the path to the container; this release sends the
  file. Several files are not sent: pipe them in, as above.
- **Right after a start, pods show their old state.** For a few seconds
  the cluster reports what it last knew; `kubectl -n NAMESPACE rollout
  status deployment/NAME` waits until they really run.

## What is not there

- **An ingress.** k3s's Traefik is off, because ports 80 and 443 of the
  node are Keg's. Use `port-forward`, or a LoadBalancer Service and
  `--publish`.
- **NodePorts from your computer**, unless published one by one with
  `--publish`.
- **More than one node.** It is one k3s server, and nothing joins it.
- **GPUs.** Nothing passes a GPU to the cluster.
- **Images shared with Keg's store.** Each is brought over with `keg k8s
  load`.
