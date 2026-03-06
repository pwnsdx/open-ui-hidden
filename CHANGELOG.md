# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- CI smoke test now probes TLS policy at runtime and verifies that a classical
  `X25519` handshake is rejected.
- GitHub release workflow on tags (`v*`) that publishes notes extracted from
  `CHANGELOG.md`.
- Maintenance helper script and Makefile targets to check or refresh pinned
  upstream image digests in place.
- `webui-fw` firewall sidecar that owns the WebUI network namespace and
  enforces a default-drop outbound TCP policy with explicit local allow-rules.

### Changed

- Tor container build now installs the `tor` package without pinning an exact
  Alpine patch revision to avoid CI breakage when package indexes rotate.
- Critical internal WebUI paths now use fixed internal IPv4 addresses to avoid
  Docker IPv6 resolution surprises inside the shared firewall namespace.

## [0.1.0] - 2026-03-03

### Added

- Dockerized Open-WebUI deployment behind a Tor hidden service.
- Dedicated `pq-proxy` (Nginx + BoringSSL) with strict PQ-only TLS groups:
  `X25519MLKEM768:X25519Kyber768Draft00`.
- `run.sh` bootstrap script for environment generation, certificate generation,
  and stack startup.
- Static and Docker smoke tests via GitHub Actions.
- Security hardening defaults (non-root users, read-only rootfs, tmpfs,
  healthchecks, capability drops).
