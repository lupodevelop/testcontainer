<!-- markdownlint-disable MD024 -->

# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-04-29

### Fixed

- `start/1` no longer fails with `PortMappingParseFailed("no host
  binding in inspect for port key: …")` when an image declares
  `EXPOSE` for ports the user never requested via `expose_port/2`.
  Docker surfaces those ports in `NetworkSettings.Ports` with a
  `null` binding list; the parser now skips them instead of treating
  them as an error. Real malformed entries (unknown port spec,
  unparseable host port number) still fail fast.
  Affected images observed in the wild include `mysql:8.4`
  (`33060/tcp`) and `rabbitmq:*-management` (`15671/tcp`,
  `4369/tcp`, `25672/tcp`, …).

## [1.0.0] - 2026-04-26

First public release. Package name: **`testcontainer`** (the plural form
is taken on Hex).

### Added

#### Public API

- `testcontainer`:
  - Lifecycle: `start/1`, `stop/1`, `start_and_keep/1`,
    `with_container/2`, `with_container_mapped/3`, `with_formula/2`,
    `with_network/2`, `with_stack/2`
  - Runtime ops: `exec/2` (separate stdout/stderr), `logs/1`,
    `logs_tail/2`, `copy_file_to/3`
- `testcontainer/container` builder: `new/1`, `with_env/3`,
  `with_envs/2`, `with_secret_env/3`, `expose_port/2`, `expose_ports/2`,
  `wait_for/2`, `with_command/2`, `with_entrypoint/2`,
  `with_bind_mount/3`, `with_readonly_bind/3`, `with_tmpfs/2`,
  `with_volume/2`, `on_network/2`, `with_name/2`, `with_label/3`,
  `with_privileged/1`. `Volume` is opaque, built via `bind_mount/2`,
  `readonly_bind_mount/2`, or `tmpfs/1`.
- `testcontainer/wait`: `none`, `log`, `log_times`, `port`, `http`,
  `http_with_status`, `health_check`, `command`, `all_of`, `any_of`,
  plus `with_timeout/2` and `with_poll_interval/2` modifiers.
- `testcontainer/network`: `create/1`, `remove/1`, `with_network/2`.
  Backed by a linked guard process so a parent crash still triggers
  network removal.
- `testcontainer/formula`: bridge type consumed by the separate
  `testcontainer_formulas` package.
- `testcontainer/port`: validated constructors `try_tcp/1` / `try_udp/1`
  return `Error.InvalidPort` for out-of-range numbers.
- `testcontainer/stack`: typed multi-container builders.

#### Lifecycle & cleanup

- Linked guard process per container/network using
  `proc_lib:spawn_link` so the link is established atomically with
  the spawn, with no leak window on caller crash during startup.
- `with_*` functions surface cleanup failures when the body succeeded,
  so a leaked container/network is never silent.
- `start_and_keep/1` forces the keep flag regardless of
  `TESTCONTAINERS_KEEP`.
- `testcontainer.force_stop/1` tears down a container regardless of
  the keep flag (works on containers started with `start_and_keep/1`
  or under `TESTCONTAINERS_KEEP=true`).
- `TESTCONTAINERS_STOP_TIMEOUT` env var (default `10`s) controls the
  stop grace period across `stop/1`, wait-failure cleanup, and the
  guard's crash-cleanup spawn.
- `Container` carries the configured stop timeout; internal
  `container.stop_timeout_sec/1` accessor exposes it to lifecycle code.

#### Configuration

- Env-driven via [`envie`](https://hex.pm/packages/envie):
  `DOCKER_HOST`, `TESTCONTAINERS_KEEP`, `TESTCONTAINERS_PULL_POLICY`,
  `TESTCONTAINERS_HOST_OVERRIDE`, `TESTCONTAINERS_REGISTRY_USER`,
  `TESTCONTAINERS_REGISTRY_PASSWORD`.
- Pull policies: `always` / `missing` / `never`. `never` returns a
  clear `ImagePullFailed` if the image is missing locally.
- Private registries supported via `X-Registry-Auth`.

#### Robustness

- Pull-stream error detection: Docker's "200 OK with embedded error
  payload" pattern is reported as `ImagePullFailed` instead of
  cascading into a cryptic create error.
- CR/LF validation on image references, container names, and volume
  paths.
- Port range validation (`1..=65535`) returning `Error.InvalidPort`.
- `port_mapping` keyed by `(port_number, protocol)` so TCP and UDP
  ports with the same number do not collide.
- `start/1` fails fast with `PortMappingParseFailed(container_id, reason)`
  when Docker's inspect port mapping cannot be decoded, instead of
  silently falling back to an empty mapping.

#### Secrets

- Env values are wrapped in [`cowl.Secret`](https://hex.pm/packages/cowl)
  so they never appear in `string.inspect` output. 
#### Other

- `DOCKER_HOST=tcp://host:port` supported as plain HTTP/1.1
  (TLS planned separately).
- MIT licence.

### Internal

- `wait_runner.run/3` takes the resolved host as an argument; the
  runner no longer calls `config.load()` on every poll.
- The wait-runner fetches the container's inspect payload once per
  poll iteration and reuses it for every port resolution and health
  check inside that iteration (including nested `all_of` / `any_of`).
- `internal/docker.url_encode` rewritten as a single grapheme-pass
  instead of 11 sequential `string.replace` calls.
- `scan_pull_stream_for_error` rewritten as a single `split_once` pass.
- `encode_registry_auth` emits standard base64 (no padding) instead
  of URL-safe base64, matching the Docker SDK reference encoding.
- `config.parse_pull_policy` is case-insensitive (`ALWAYS`, `Always`,
  and `always` all map to `Always`).
- `wait.with_timeout/2` clamps negative values to `0`;
  `wait.with_poll_interval/2` clamps values `< 1` to `1` to prevent a
  hot-spin loop.
- `with_container_mapped/3` destructures the guarded result inline
  for clarity (no behaviour change).

### Notes

- `woof` is a dev-only dependency. The library core does not log;
  applications can wire their own logging on top of the public API.

### Naming

- `container.named/2` → `container.with_name/2`
- `container.privileged/1` → `container.with_privileged/1`
- `Volume` is now opaque. Construct via `container.bind_mount/2`,
  `readonly_bind_mount/2`, or `tmpfs/1` instead of the data
  constructors.
