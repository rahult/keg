# Testing Keg

This document covers testing Keg's Docker API compatibility and Kubernetes integration using standard `docker` and `kubectl` CLIs.

## Docker API

Keg exposes a Docker-compatible API server via Unix socket at:
- `/var/run/docker.sock` (if writable)
- `~/.keg/docker.sock` (fallback)

Set `DOCKER_HOST` before running Docker CLI commands:

```bash
export DOCKER_HOST=unix:///var/run/docker.sock
```

### Verify connection

```bash
docker info
```

### Container operations

```bash
# List all containers
docker ps -a

# Pull an image
docker pull alpine:latest

# Run a container
docker run --rm -d --name test-container alpine:latest sleep 60

# View logs
docker logs test-container

# Inspect a container
docker inspect test-container

# Stop and remove
docker stop test-container
docker rm test-container
```

### Image operations

```bash
# List images
docker images

# Remove an image
docker rmi alpine:latest
```

### Build (if supported)

```bash
docker build -t myapp:latest ./path/to/dockerfile
```

## Kubernetes

Kubeconfig is generated at `~/.keg/kubeconfig` after cluster creation via the Keg UI (Kubernetes section).

> **Note**: Create the K8s cluster through the Keg UI first. Single-node clusters use the `kindest/node` image with kubeadm inside an Apple Container.

### Configure kubectl

```bash
export KUBECONFIG=~/.keg/kubeconfig
```

### Verify cluster

```bash
# Check cluster info
kubectl cluster-info

# List nodes
kubectl get nodes -o wide
```

### Deploy workloads

```bash
# Create a deployment
kubectl create deployment nginx --image=nginx:latest

# Check status
kubectl get deployments,pods,services

# View pod logs
kubectl logs -l app=nginx

# Scale the deployment
kubectl scale deployment nginx --replicas=3
kubectl get pods

# Delete the deployment
kubectl delete deployment nginx
```

### Useful kubectl shortcuts

```bash
# Watch pods live
kubectl get pods -w

# Describe a resource
kubectl describe pod <pod-name>

# Execute into a pod
kubectl exec -it <pod-name> -- /bin/sh

# Port forward to local
kubectl port-forward svc/nginx 8080:80

# Check resource usage
kubectl top nodes
kubectl top pods
```

## Smoke Test Script

Run this to verify both Docker API and Kubernetes are working:

```bash
#!/bin/bash
set -e

# Test Docker API
export DOCKER_HOST=unix:///var/run/docker.sock
echo "=== Docker API ==="
docker info | head -3
docker run --rm --name smoke-test alpine echo "Keg Docker API works!"
docker rmi alpine

# Test Kubernetes
export KUBECONFIG=~/.keg/kubeconfig
echo ""
echo "=== Kubernetes ==="
kubectl get nodes
kubectl create job smoke --image=alpine -- echo "K8s works!"
kubectl logs job/smoke
kubectl delete job smoke
```

## Troubleshooting

### Docker socket not found

Keg's Docker API auto-starts when the system is running. Ensure:
1. Keg app is running
2. Container system is started via the UI
3. `dockerAPIAutoStart` is enabled in settings

### Kubernetes cluster not found

The K8s cluster must be created through the Keg UI (Kubernetes section). Check the output panel for errors during cluster creation.

### Connection refused

If you see `Cannot connect to the Docker daemon`, verify the socket exists:

```bash
ls -la /var/run/docker.sock ~/.keg/docker.sock 2>/dev/null || echo "Socket not found"
```

Restart the Docker API server via the Keg UI settings.
