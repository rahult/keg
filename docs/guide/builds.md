# Building images

The **Builds** section builds images from a Dockerfile using the same builder
the `container build` CLI uses.

## Build an image

1. Sidebar → **Builds**.
2. **Context** — the project folder that contains your Dockerfile (click
   **Browse…** to pick it; leave empty to use the current folder).
3. **Dockerfile** — path relative to the context, or an absolute path
   (default `Dockerfile`).
4. **Tags** — one or more comma-separated references, for example
   `my-image:latest, registry.example.com/team/my-image:v1`.
5. **Build args** — `KEY=value` pairs separated by commas.
6. **Platform** — defaults to `linux/arm64`.
7. Toolbar → **Build**. Output streams into the Build Output pane.

## Options

- **Disable cache** — build every layer from scratch.

## Builder resources

The builder runs as its own container. Set its default CPUs, memory, and
Rosetta translation in
[Settings → Apple Containers → Platform → Builds](settings.md#apple-containers).

## Tips

- Pin a tag — an untagged build lands on `latest` and is easy to lose track
  of.
- The builder image itself is configurable in Settings (advanced users only;
  the platform default matches the installed CLI).
