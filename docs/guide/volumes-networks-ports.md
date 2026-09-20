# Volumes, networks & ports

These three sections under **System** cover the resources around your
containers.

## Volumes

Named volumes persist data beyond a container's lifecycle.

- Sidebar → **Volumes** → **Create Volume…** and give it a name.
- Attach a volume when running a container, or reference it from a Compose
  file.
- Delete from the row's context menu — data is removed with it.

Volumes live under the configured data location
([Settings → Apple Containers → Data Location](settings.md#data-location)),
in the `volumes/` folder.

## Networks

Lists container networks with their subnets. Every container joins the
`default` network unless configured otherwise; containers reach each other by
IP on that network.

## Ports

Shows every published port across **running** containers — container name,
host port, container port. Search by container, port, or URL to find the one
you want. Publish ports at run time with `host:container` pairs in the Run
sheet.
