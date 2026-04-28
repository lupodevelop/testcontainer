# Configuration

All knobs are environment variables. They are read once per
`testcontainer.start/1` call and need no setup code in your tests.

## `DOCKER_HOST`

How `testcontainer` reaches the daemon.

| Value                          | Behaviour                          |
|--------------------------------|------------------------------------|
| _(unset)_                      | `unix:///var/run/docker.sock`      |
| `unix:///path/to/docker.sock`  | Unix domain socket at that path    |
| `tcp://host:port`              | Plain TCP HTTP/1.1 (no TLS)        |

For Docker Desktop on macOS (Colima, Rancher Desktop, OrbStack…) the
default Unix path usually works because Docker Desktop forwards a
Unix socket into your $HOME. If your setup is non-standard,
point `DOCKER_HOST` at the socket file directly.

For remote CI runners hosting Docker on a TCP endpoint, use the
`tcp://...` form. TLS is not handled in 0.1 - terminate it upstream
or stick with Unix sockets.

## `TESTCONTAINERS_KEEP`

`true` to leave the container running for inspection after the test
finishes (useful when something is failing and you want to `docker
logs` / `docker exec` it). `false` (default) means stop+remove on
test exit.

## `TESTCONTAINERS_PULL_POLICY`

When `start/1` should pull the image:

- `missing` (default) - pull only if not present locally
- `always` - pull every time
- `never` - fail with a clear `ImagePullFailed` if missing locally
  (great for hermetic CI: pre-pull images, then refuse network)

## `TESTCONTAINERS_HOST_OVERRIDE`

Hostname/IP your test runner should use to reach mapped ports.
Default is `127.0.0.1`, which works for Docker Desktop / Colima /
plain Linux Docker. Set this when the daemon lives somewhere else
(remote host, separate VM):

```sh
export TESTCONTAINERS_HOST_OVERRIDE=ci-docker.internal
```

`Container.host/1` and `Container.mapped_url/3` will return that
host instead of `127.0.0.1`.

## `TESTCONTAINERS_REGISTRY_USER` / `TESTCONTAINERS_REGISTRY_PASSWORD`

Credentials sent as `X-Registry-Auth` on `POST /images/create` for
private images. Both must be set together; the password is wrapped
in a `cowl.Secret` internally so it doesn't leak through
`string.inspect` / logs.

```sh
export TESTCONTAINERS_REGISTRY_USER=ci-bot
export TESTCONTAINERS_REGISTRY_PASSWORD="$REGISTRY_TOKEN"
```

If the variables are unset, no auth header is sent and pulls go
through unauthenticated.

## Secrets

Env vars set on the container via `container.with_env/3` or
`container.with_envs/2` are wrapped in `cowl.Secret` automatically.
They never appear in `string.inspect(spec)` and are only revealed
when serialised to the Docker API at create time. There's a unit
test (`with_env_does_not_leak_value_in_inspect_test`) that pins this
behaviour.
