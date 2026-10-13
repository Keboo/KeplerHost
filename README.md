# .NET 10 dev container (SSH-accessible)

A Docker image with the .NET 10 SDK, git, and npm, reachable over SSH with
key-only auth.

## Files

- `Dockerfile` — builds on `mcr.microsoft.com/dotnet/sdk:10.0`, adds git,
  Node.js/npm (via NodeSource), an `openssh-server`, and a non-root `dev`
  user with passwordless sudo.
- `entrypoint.sh` — runs **inside the Linux container** at startup
  (generates any missing SSH host keys, then execs `sshd`). Left as
  bash intentionally — it's container-internal, not something you run
  yourself, and bash is guaranteed present in the base image while
  PowerShell is not.
- `generate-keys.ps1` — run on your machine. Creates a dedicated ed25519
  keypair (`~/.ssh/id_dotnet10dev_ed25519` by default) and copies the public
  half into this folder as `authorized_keys`, which the Dockerfile bakes
  into the image.
- `up.ps1` — builds the image and starts the container, publishing SSH on
  `localhost:2222`. A per-container Docker volume retains SSH host keys
  across rebuilds and recreation.
- `down.ps1` — stops and removes the container, retaining its host-key volume.
- `azure-up.ps1` — builds the *same* Dockerfile in Azure Container Registry
  and runs it as an Azure Container Instance (cloud agent host).
- `azure-down.ps1` — deletes the container instance (optionally the
  registry / whole resource group).
- `azure-common.ps1` — shared helpers for the two Azure scripts; not meant
  to be run directly.

All host-side scripts are PowerShell Core (`pwsh`) — install it if you
don't have it (`winget install Microsoft.PowerShell` / `brew install
powershell` / etc.).

## Steps

1. **Generate the SSH keypair** (do this wherever you'll build/run the
   container):
   ```powershell
   ./generate-keys.ps1
   ```
   This never sets a password — auth is key-only.
   Older versions of this script could accidentally set the key passphrase
   to two double-quote characters (`""`) on modern PowerShell. Existing keys
   are not overwritten. If affected, use `ssh-keygen -p -f
   "$HOME\.ssh\id_dotnet10dev_ed25519"`, enter those two characters as the old
   passphrase, and leave the new passphrase empty.

2. **Build and start the container**:
   ```powershell
   ./up.ps1
   ```

3. **Connect over SSH**:
   ```bash
  ssh -i ~/.ssh/id_dotnet10dev_ed25519 -p 2222 dev@localhost
   ```
   - **Host**: `localhost` (port `2222` is mapped to the container's `22`;
     change with `up.ps1 -SshPort <port>` if 2222 is taken)
   - **User**: `dev` (passwordless sudo inside the container)

4. **Verify the tooling** once connected:
   ```bash
   dotnet --version   # should report a 10.x SDK
   git --version
   npm --version
   ```

5. **Tear down** when done:
   ```powershell
   ./down.ps1
   ```

## Local container identities

`up.ps1` mounts the named Docker volume `<ContainerName>-ssh-host-keys`.
Re-running it or running `down.ps1` followed by `up.ps1` retains the same
SSH server identity, without disabling SSH host-key verification. Keep the
same container name and SSH port when reconnecting.

For multiple local containers, use a different name and port for each:

```powershell
./up.ps1 -ContainerName agent-1 -SshPort 2223
./up.ps1 -ContainerName agent-2 -SshPort 2224
./down.ps1 -ContainerName agent-1
```

### Updating your SSH `known_hosts`

SSH saves the **server's identity** in `$HOME\.ssh\known_hosts`. This is
separate from your login key (`id_dotnet10dev_ed25519`) and the container's
`authorized_keys`. A `REMOTE HOST IDENTIFICATION HAS CHANGED!` warning
means the saved server identity does not match; it does not mean you
selected the wrong login key.

An update is expected when migrating an existing container to this
volume-based setup, deliberately replacing or deleting its host-key volume,
or reusing the same host and port for a different container. Normal
rebuilds and `down.ps1` / `up.ps1` cycles with the same retained volume
should **not** require an update. Older images without the persistent-key
entrypoint can change identity every time they are recreated; rebuild
with the updated `up.ps1` to migrate them.

Do not remove a trust entry just because SSH reports a warning. First
verify the new identity through a trusted channel. For your own local
Docker container, read its ED25519 fingerprint directly:

```powershell
docker exec dotnet10-dev ssh-keygen -lf /var/lib/ssh-host-keys/etc/ssh/ssh_host_ed25519_key.pub
```

If the container is still running an older image, its keys are instead
under `/etc/ssh`:

```powershell
docker exec dotnet10-dev ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Compare that fingerprint with the ED25519 fingerprint in the SSH warning.
If they match and the identity change is expected, remove only the stale
entry and reconnect:

```powershell
ssh-keygen -R "[localhost]:2222"
ssh -i "$HOME\.ssh\id_dotnet10dev_ed25519" -p 2222 dev@localhost
```

Accept the new fingerprint only if it matches the verified one printed by
`docker exec`. SSH then saves it for subsequent connections. `ssh-keygen -R`
keeps the previous file as `known_hosts.old`; it does not clear unrelated
hosts. If you use a custom trust file, pass `-f <path>` to `ssh-keygen` and
`-o UserKnownHostsFile=<path>` to `ssh`.

Substitute your container name, connection hostname, and port if customized
(for example, `[localhost]:2223` or `[127.0.0.1]:2222`). On the default SSH
port 22, use the hostname alone rather than `[hostname]:port`. Do not
disable host-key checking or delete the whole `known_hosts` file. If the
fingerprints differ or the change is unexplained, stop and investigate.

To intentionally discard a server identity, remove its volume after
stopping the container (for example, `docker volume rm
dotnet10-dev-ssh-host-keys`). Its next start generates new keys and
requires verifying the new fingerprint again. Volume pruning can also
discard keys for stopped containers.

Azure starts still use ephemeral host keys unless a persistent volume is
mounted at `/var/lib/ssh-host-keys`.

## Running it in Azure (cloud agent host)

Same image, same dependencies — just hosted in
[Azure Container Instances](https://learn.microsoft.com/azure/container-instances/)
instead of on your machine. Requires the
[Azure CLI](https://aka.ms/azure-cli) and `az login`.

```powershell
./generate-keys.ps1     # if you haven't already
./azure-up.ps1
```

`azure-up.ps1` will:

1. create the resource group (default `dotnet10-dev-rg`, region `eastus`),
2. create an Azure Container Registry with the admin user enabled (ACI
   pulls with a username/password),
3. run `az acr build` on this folder — the build happens in Azure but uses
   the exact same `Dockerfile`, so the container instance gets the identical
   dotnet 10 SDK / git / node / sshd setup as the local one,
4. create a container instance with a public IP, a DNS label, and port 22
   open.

Steps 3 and 4 are skipped when there's nothing to do. The image is tagged with
a hash of the build inputs — the `Dockerfile` plus every file it `COPY`s
(`authorized_keys`, `entrypoint.sh`) — so re-running `azure-up.ps1` with no
edits finds that tag already in the registry and skips the build entirely.
Editing the README or one of the `.ps1` scripts doesn't affect the image, so it
doesn't trigger a rebuild. Likewise, if the container instance is already
running that exact image, it's left alone instead of being deleted and
recreated (which would change the public IP). Use `-ForceBuild` to rebuild and
redeploy regardless.

When it finishes it prints the FQDN and the SSH command:

```bash
ssh -i ~/.ssh/id_dotnet10dev_ed25519 dev@<container>.<region>.azurecontainer.io
```

You can also get a shell without SSH at all, per
[the ACI exec docs](https://learn.microsoft.com/azure/container-instances/container-instances-exec):

```powershell
az container exec --resource-group dotnet10-dev-rg --name dotnet10-dev --exec-command "/bin/bash"
```

Note that `az container exec` can only launch a single process and can't take
command arguments — it's for interactive debugging, not scripting. Use SSH
for real work.

**Tear down** (do this when you're done — ACI bills per second while the
container group exists):

```powershell
./azure-down.ps1                        # delete just the container instance
./azure-down.ps1 -IncludeRegistry       # also delete the ACR
./azure-down.ps1 -DeleteResourceGroup   # delete everything, prompts first
```

Keeping the registry between runs makes the next `azure-up.ps1` faster
(layer cache) but costs a few dollars a month for a Basic ACR.

Useful knobs:

```powershell
./azure-up.ps1 -ResourceGroup my-agents -Location westus2 -Cpu 4 -Memory 8
./azure-up.ps1 -ContainerName agent-2 -DnsLabel my-unique-label
./azure-up.ps1 -ForceBuild                # rebuild + redeploy even if unchanged
```

The registry name and DNS label default to values derived from the resource
group name, so `azure-up.ps1` and `azure-down.ps1` agree on them without you
having to pass anything. If you override one, pass the same value to both.

## Notes / things you may want to adjust

- `PasswordAuthentication` is disabled in `sshd_config` — key-only login,
  per your earlier choice.
- The Node.js major version is a build arg: `docker build --build-arg
  NODE_MAJOR=24 ...` if you'd rather track the newer LTS instead of the
  default (22).
- `authorized_keys` is gitignored — don't commit it or the private key if
  this folder ever becomes a git repo.
- The Azure container instance exposes port 22 to the public internet.
  That's only key-only SSH, but if you want it locked down further, drop
  `--ip-address Public` / `--dns-name-label` from `azure-up.ps1`, deploy
  into a VNet, and reach it over `az container exec` or a private endpoint.
- If you're running Docker Desktop on a remote/VM host rather than
  locally, swap `localhost` for that host's address in the SSH command.
