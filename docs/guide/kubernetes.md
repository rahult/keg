# Kubernetes

Keg can bootstrap a **single-node Kubernetes cluster** inside an Apple
Container — a `kindest/node`-based image configured with kubeadm, similar in
spirit to kind.

## Create a cluster

1. Sidebar → **Kubernetes**.
2. **Name** — defaults to `keg-k8s`.
3. **Node Image** — defaults to a pinned `kindest/node` release.
4. Toolbar → **Create Cluster**. The bootstrap output streams into the pane
   (join, control plane, CNI).
5. When it finishes, the cluster is **running** and a kubeconfig has been
   written to `~/.keg/kubeconfig`.

## Use the cluster

```sh
export KUBECONFIG=~/.keg/kubeconfig
kubectl get nodes
```

Keg's embedded Terminal sets `KUBECONFIG` automatically.

## Start / stop / delete

- **Start Cluster** / **Stop Cluster** start and stop the cluster container.
- **Delete Cluster** removes the `keg-k8s` container *and* the kubeconfig —
  all cluster state is lost. Keg asks for confirmation first.

The [Kubernetes tab in Settings](settings.md#kubernetes) shows the same
status with start/stop shortcuts.

## Notes

- Single-node only; multi-node clusters are not supported yet.
- The node image is configurable — pin it to match the Kubernetes version
  you develop against.
