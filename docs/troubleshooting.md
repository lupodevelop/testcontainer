# Troubleshooting

Common failure modes and how to read them.

## `DockerUnavailable("/var/run/docker.sock", reason)`

The daemon is not reachable.

- Is Docker actually running? `docker version` from the same shell.
- On macOS, Docker Desktop forwards a Unix socket to `$HOME`.
  If your `DOCKER_HOST` is unset, the library defaults to
  `/var/run/docker.sock`. Symlink or set `DOCKER_HOST` explicitly:

  ```sh
  export DOCKER_HOST=unix://$HOME/.docker/run/docker.sock
  ```

- TCP daemons: confirm `tcp://...` URL and that no proxy intercepts.

## `ImagePullFailed(image, "TESTCONTAINERS_PULL_POLICY=never and image not present locally")`

Self-explanatory: with `pull_policy=never`, the image must already be
in the local cache. Either pre-pull (`docker pull alpine:3.18`) or
relax the policy.

## `ImagePullFailed(image, reason)` mid-stream

Docker returns HTTP 200 even when an image pull fails halfway -
auth, network, manifest mismatch. The library scans the streamed
JSON body for `errorDetail` / `error` and surfaces the first message
it finds. Common causes:

- Private image without `TESTCONTAINERS_REGISTRY_USER` /
  `TESTCONTAINERS_REGISTRY_PASSWORD` set.
- Rate limit (`toomanyrequests`) - log in to Docker Hub.
- Manifest unknown - typo in tag.

## `ContainerStartFailed`

The container was created but Docker refused to start it. Causes:

- Port already in use (when you set `HostPort` explicitly - the
  default is dynamic, so this rarely happens).
- Volume bind path doesn't exist on the host.
- Image entrypoint crashed immediately.

`docker logs <id>` (use `TESTCONTAINERS_KEEP=true` so the container
sticks around) usually clarifies.

## `InvalidPort(number)`

The port is outside `1..=65535`.

- `port.try_tcp/1` and `port.try_udp/1` return this immediately.
- `port.tcp/1` / `port.udp/1` defer validation to startup; `start/1`
  returns `InvalidPort(number)` before create/start calls continue.

## `WaitTimedOut(strategy, elapsed_ms)`

Your wait strategy didn't succeed within its configured timeout.
`elapsed_ms` is real wall-clock time. Tactics:

- Bump the timeout: `wait.with_timeout(120_000)`.
- Add a second probe via `wait.all_of([port, log])` - sometimes the
  port opens before the app is really ready.
- Inspect with `TESTCONTAINERS_KEEP=true` and `docker logs <id>` -
  the log line you're matching may not be exactly what you expect.
- Health-check images: `wait.health_check()` only terminates if the
  image has a `HEALTHCHECK` defined.

## `WaitFailed(strategy, reason)`

Same family as `WaitTimedOut`, but the strategy reported a reason
that's not just "no signal yet" (e.g. HTTP returned a clearly wrong
status repeatedly). The `reason` field carries the latest probe
output.

## `ExecFailed(id, cmd, exit_code, stderr)`

The Docker API call to start exec returned an error, OR the exit
code couldn't be parsed. Note: a non-zero exit from your command is
**not** an error - you get `Ok(ExecResult(exit_code: N, ...))`.
`ExecFailed` is reserved for "Docker said no".

## `PortMappingParseFailed(container_id, reason)`

`docker inspect` succeeded, but `NetworkSettings.Ports` was not in the
expected format. This is treated as a hard error (no silent fallback),
so mapped-port calls don't fail later with misleading `PortNotMapped`.

## My test passed but a container is still running

This shouldn't happen with `with_container`. If it does:

- Check that you're using `with_container` (or `with_formula`), not
  bare `start/1`.
- Check `TESTCONTAINERS_KEEP` is not set to `true` in your shell.
- The crash-cleanup is **fire-and-forget** by design. If the BEAM
  itself exits abruptly (kernel-level crash, `kill -9`), pending
  cleanups don't run. The next `with_container` call with the same
  `with_name(...)` will conflict - remove manually with
  `docker rm -f <name>`.

## Docker Desktop is slow on first pull

The very first `with_container` after a reboot can take longer than
the default 60 s wait timeout while Docker pulls the image and warms
up. Either:

- Pre-pull images in CI, then run with `pull_policy=never`.
- Bump the strategy timeout for the initial test.
