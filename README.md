# .NET 10 dev container (SSH-accessible)

A Docker image with the .NET 10 SDK, git, and npm, reachable over SSH with
key-only auth.

## Files

- `Dockerfile` — builds on `mcr.microsoft.com/dotnet/sdk:10.0`, adds git,
  Node.js/npm (via NodeSource), an `openssh-server`, and a non-root `dev`
  user with passwordless sudo.
- `entrypoint.sh` — runs **inside the Linux container** at startup
  (generates SSH host keys on first boot, then execs `sshd`). Left as
  bash intentionally — it's container-internal, not something you run
  yourself, and bash is guaranteed present in the base image while
  PowerShell is not.
- `generate-keys.ps1` — run on your machine. Creates a dedicated ed25519
  keypair (`~/.ssh/id_dotnet10dev_ed25519` by default) and copies the public
  half into this folder as `authorized_keys`, which the Dockerfile bakes
  into the image.
- `up.ps1` — builds the image and starts the container, publishing SSH on
  `localhost:2222`.
- `down.ps1` — stops and removes the container.

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

## Notes / things you may want to adjust

- `PasswordAuthentication` is disabled in `sshd_config` — key-only login,
  per your earlier choice.
- The Node.js major version is a build arg: `docker build --build-arg
  NODE_MAJOR=24 ...` if you'd rather track the newer LTS instead of the
  default (22).
- `authorized_keys` is gitignored — don't commit it or the private key if
  this folder ever becomes a git repo.
- If you're running Docker Desktop on a remote/VM host rather than
  locally, swap `localhost` for that host's address in the SSH command.
