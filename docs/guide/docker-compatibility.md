# Docker compatibility

Keg serves a **Docker Engine API on a Unix socket**, so the standard `docker`
CLI — and every tool built on the Docker API — works against Apple containers
without a Docker daemon.

## Point the docker CLI at Keg

```sh
export DOCKER_HOST=unix://~/.keg/docker.sock
docker ps
docker run -d -p 8080:80 docker.io/library/nginx:latest
docker compose up
```

Copy the exact command from **Settings → Docker** (one-click copy button).

## Enable the API server

- **Settings → Docker → Start Docker API automatically** — binds the socket
  as soon as the runtime is up.
- The socket lives at `~/.keg/docker.sock` by default.
- Start/Stop is also available right in the Docker tab.

## What works

- `docker ps`, `run`, `stop`, `rm`, `inspect`, `logs`, `exec`
- Port publishing and environment variables
- `docker compose` (the Compose section wraps the same project files)
- Language SDKs and IDE integrations that speak the Docker API

## Notes

- The API server starts only when the container runtime is running; Keg
  starts the runtime automatically when needed.
- Streaming endpoints (attach/port-forward) have partial support today.
