#!/bin/bash
set -e

# Host keys aren't baked into the image (they'd be shared/predictable across
# every build) — generate them fresh on first boot of a given container.
ssh-keygen -A

exec /usr/sbin/sshd -D -e
