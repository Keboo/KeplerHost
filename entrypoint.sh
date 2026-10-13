#!/bin/bash
set -e

# Local containers mount a dedicated volume here; cloud containers generate
# ephemeral keys. Never use the host keys installed while building the image.
host_key_root=/var/lib/ssh-host-keys
mkdir -p "$host_key_root/etc/ssh"
chmod 700 "$host_key_root" "$host_key_root/etc" "$host_key_root/etc/ssh"
ssh-keygen -A -f "$host_key_root"

exec /usr/sbin/sshd -D -e \
    -h "$host_key_root/etc/ssh/ssh_host_rsa_key" \
    -h "$host_key_root/etc/ssh/ssh_host_ecdsa_key" \
    -h "$host_key_root/etc/ssh/ssh_host_ed25519_key"
