# Tools image, not the tunnel

This folder ships the short book and, later, the offline tests. It does not run the VPN.

Windows RAS and the kill switch stay on a Windows machine. A Linux container that claims to arm that lock is a lie.

## Run the book

```text
docker compose -f docker/compose.yaml run --rm book
```

It prints the pages. It does not need the network after the image exists.

## Later

When the scrubber and host-name tests live on the same branch, add them as a second service named `tools`. Same rule: offline, read-only repo, write reports to a local folder.
