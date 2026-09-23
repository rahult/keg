# Keg Apps Registry

The curated catalog the Keg Apps section syncs from. This folder is the
registry's content, ready to be pushed to a public GitHub repo (by default
Keg looks at `raw.githubusercontent.com/rahult/keg-apps/main` — see
"Pointing Keg at the registry" below).

## Layout

```
index.yaml          # the manifest: version, updated stamp, list of apps + checksums
apps/<id>.yaml      # one catalog app definition per file
```

Each `apps/<id>.yaml` is a full catalog definition — the same format as the
ones embedded in `Sources/Keg/Apps/BundledAppCatalog.swift` (which exist only
as the offline fallback for first runs with no network). `index.yaml` lists
every app with a `sha256` of its file so the app can skip unchanged
downloads and reject corrupted ones.

## Adding or updating an app

1. Edit or add `apps/<id>.yaml` (copy an existing file as a template).
2. Recompute its checksum and update `index.yaml`:

   ```sh
   shasum -a 256 apps/<id>.yaml
   ```

3. Bump `updated:` in `index.yaml`.
4. Commit and push to the registry repo's default branch.

Clients pick it up on their next refresh — automatically once a day (on
launch or when the Apps section opens), or immediately via **Refresh
Registry** in the Apps section.

## Retiring an app

Set `hidden: true` in the app's YAML (and update its checksum in
`index.yaml`). Hidden apps disappear from the browse grid; people who
already installed them keep everything working, and Update still functions.
To retire *and* stop updates entirely, remove the entry from `index.yaml` —
installed apps then update images in place from their on-disk template.

## Precedence

Three layers merge by app id, later wins:

1. Bundled definitions in the app bundle (offline fallback)
2. This registry (the synced cache in `~/.keg/apps/remote-catalog/`)
3. Local overrides a user places in `~/.keg/apps/catalog/`

## Pointing Keg at the registry

The default base URL is
`https://raw.githubusercontent.com/rahult/keg-apps/main` (any branch/path
works — the app fetches `<base>/index.yaml` then `<base>/<file>`). To use a
different repo, fork, or a local folder while testing:

```sh
defaults write dev.rahult.keg apps.catalogURL "https://raw.githubusercontent.com/<you>/<repo>/<branch>"
# local folder (handy before the repo exists — no server needed):
defaults write dev.rahult.keg apps.catalogURL "file:///Volumes/Atlas/Code/projects/meadow/registry"
```

The only server requirement is that the files are reachable over plain HTTP
GETs; no API, auth, or special headers.
