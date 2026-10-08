# nova-cli install package

Standalone, distributable installer for `nova-cli`.

- `install.sh` — installs `nova-cli`. Uses bundled binaries in `./bin` when
  present (fully offline), otherwise downloads from GitLab.
- `make-bundle.sh` — builds the offline tarball (`dist/nova-cli-<version>.tar.gz`
  plus a `.sha256`). Only needed by whoever publishes the package.

## Install

```sh
./install.sh                       # this machine's OS/arch
./install.sh --install-dir /usr/local/bin
./install.sh --channel beta
./install.sh --version 1.4.2
./install.sh --channel alpha --alpha-ref my-branch
./install.sh --job-id 123456       # CI job artifact
./install.sh --dry-run             # show what would happen
./install.sh --uninstall
```

Defaults: install dir `~/.local/bin`, command name `nova-cli`, channel `stable`.
Every flag also has an environment variable (`NOVA_CLI_INSTALL_DIR`,
`NOVA_CLI_BIN_NAME`, `NOVA_CLI_CHANNEL`, `NOVA_CLI_VERSION`,
`NOVA_CLI_ALPHA_REF`, `NOVA_CLI_JOB_ID`, `NOVA_CLI_DRY_RUN`,
`NOVA_CLI_GITLAB_BASE_URL`, `NOVA_CLI_PAGES_BASE_URL`). Run `./install.sh --help`
for the full list.

`GITLAB_TOKEN`, if set, is sent as `PRIVATE-TOKEN` for Release and job-artifact
downloads. It is not needed for the default stable channel (GitLab Pages) or for
offline installs.

## Offline / air-gapped install

The bundle built by `make-bundle.sh` contains binaries for
`linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`:

```sh
tar -xzf nova-cli-<version>.tar.gz
cd nova-cli-<version>
./install.sh --offline
```

`--offline` fails loudly if no binary matches the current platform rather than
silently falling back to the network. `--online` forces a download even when a
bundled binary exists.

Every install path verifies the binary's SHA-256 against `checksums.txt` before
moving it into place — bundled binaries against the `checksums.txt` shipped in
the package, downloads against the upstream one.

## Building the package

```sh
./make-bundle.sh                                   # latest stable, all platforms
./make-bundle.sh --channel beta
./make-bundle.sh --version 1.4.2
./make-bundle.sh --platforms "darwin_arm64 linux_amd64"
./make-bundle.sh --out /tmp/releases
```

`make-bundle.sh` verifies each downloaded binary against the upstream
`checksums.txt` and copies only verified entries into the package, so a bundle
can never ship an unverified binary.

## Supported platforms

Linux and macOS, on amd64 and arm64. Requires a POSIX `sh`; online installs also
need `curl`, and all installs need `sha256sum` or `shasum`.

## After installing

```sh
nova-cli --version
nova-cli auth login-jwt
```
