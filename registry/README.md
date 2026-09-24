# Keg Apps Registry

The curated catalog the Keg Apps section syncs from. It lives in this repo
at `registry/`, served to clients through GitHub raw URLs — by default Keg
fetches `https://raw.githubusercontent.com/rahult/keg/main/registry/index.yaml`
and the files it lists.

Publishing is just a push to `main`: clients re-sync (about once a day, or
via **Refresh Registry** in the Apps section) and pick up the change. No Keg
release is involved — the app bundles the same definitions only as an
offline fallback for first runs before the first successful sync.

## Layout

```
index.yaml          # the manifest: version, updated stamp, list of apps + checksums
apps/<id>.yaml      # one catalog app definition per file
```

Each `apps/<id>.yaml` is a full catalog definition — the same format as the
ones embedded in `Sources/Keg/Apps/BundledAppCatalog.swift`. `index.yaml`
lists every app with a `sha256` of its file so the app can skip unchanged
downloads and reject corrupted ones.

## Adding or updating an app

1. Edit or add `apps/<id>.yaml` (copy an existing file as a template).
2. Recompute its checksum and update `index.yaml`:

   ```sh
   shasum -a 256 apps/<id>.yaml
   ```

3. Bump `updated:` in `index.yaml`.
4. Commit and push to `main`.

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

## Pointing Keg elsewhere

The default base URL is the `registry/` folder of this repo on `main`. The
base is whatever directory contains `index.yaml` — the app fetches
`<base>/index.yaml` then `<base>/<file>` — so overrides are one
`defaults write` away:

```sh
# A staging branch of this repo, to try templates before merging to main:
defaults write dev.rahult.keg apps.catalogURL "https://raw.githubusercontent.com/rahult/keg/staging/registry"
# A local folder while offline (no server needed):
defaults write dev.rahult.keg apps.catalogURL "file:///path/to/meadow/registry"
```

Note for hosting: raw fetches are unauthenticated, so clients can only sync
while the repo is public. If the repo is ever made private, the Apps
section falls back to the bundled catalog and the Refresh button reports
the 404.
