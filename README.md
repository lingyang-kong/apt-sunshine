# Sunshine APT Repository

Independent, signed APT mirror for upstream [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) release packages.

The repository mirrors upstream stable `.deb` assets and republishes them as a GitHub Pages APT archive. `apt` then handles installation and upgrades in the normal way.

This mirror is unofficial. It is not operated, sponsored, or endorsed by LizardByte or the Sunshine project.

## Layout

- `scripts/sync-apt-repo.sh`: builds the archive.
- `templates/`: checked-in site and manifest templates.
- `dist/`: generated GitHub Pages site.
- `dist/dists/` and `dist/pool/`: conventional APT metadata and package storage.

## What It Publishes

- Stable upstream releases only.
- Upstream Debian and Ubuntu `.deb` assets using the current `sunshine_<version>+<distribution><release>_<arch>.deb` format, the previous `sunshine-<suite>-<arch>.deb` format, or supported legacy names.
- Version-specific corresponding source links for each mirrored binary via `releases.json` and the GitHub Pages index.
- The newest complete releases that fit within the 1,000,000,000-byte GitHub Pages site limit.

Current suite names follow upstream naming, for example:

- `ubuntu-22.04`
- `ubuntu-24.04`
- `ubuntu-26.04`
- `debian-trixie`

Versioned filenames map to the same suites: for example, `sunshine_2026.906.222525-1+debiantrixie_amd64.deb` maps to `debian-trixie` and architecture `amd64`.

## Automation

GitHub Actions polls the newest stable release every Monday and Thursday at 06:17 UTC. It rebuilds only when that release or any of its `.deb` asset metadata differs from the last published snapshot.

The workflow:

1. Compares the newest stable release and its `.deb` asset metadata with the published `releases.json`.
2. Stops without downloading packages when that metadata is unchanged.
3. Reads stable releases from `LizardByte/Sunshine` when a rebuild is required.
4. Calculates how much space a new release would add and evicts the oldest retained whole releases until it fits.
5. Downloads those packages and generates suite-specific `Packages`, `Release`, `InRelease`, and `Release.gpg` metadata.
6. Publishes the snapshot from `dist/` to GitHub Pages.

Retained releases coexist under `pool/main/s/sunshine/<suite>/` without overwriting each other.

## Compliance and Provenance

- The generated repository metadata uses `Origin: Unofficial Sunshine Mirror` and `Label: Unofficial Sunshine Mirror`.
- The GitHub Pages site links each mirrored binary to the upstream release page and upstream source archives for the same release.
- Original automation and templates in this repository are licensed under the MIT License in [LICENSE](LICENSE).
- Third-party licensing and attribution notes live in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Repository signing-key handling, support boundaries, and key-rotation guidance live in [SECURITY.md](SECURITY.md).

The mirror signature attests to this repository's generated APT metadata. It does not imply that upstream Sunshine maintainers signed, reviewed, or endorsed this mirror.

## Client Install

Example for Ubuntu 22.04 `amd64`:

```sh
curl -fsSL 'https://lingyang-kong.github.io/sunshine/sunshine-archive-keyring.gpg' \
  | sudo tee /usr/share/keyrings/sunshine-archive-keyring.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/sunshine-archive-keyring.gpg] https://lingyang-kong.github.io/sunshine ubuntu-22.04 main' \
  | sudo tee /etc/apt/sources.list.d/sunshine.list

sudo apt update
sudo apt install sunshine
```

Use the suite that matches the upstream package target for the host. For this machine, that is `ubuntu-22.04`.

## Support

Operational problems with this mirror should be reported to the mirror maintainer. Upstream Sunshine issues should be reported to the upstream project unless they are specific to this mirror's packaging or repository metadata.
