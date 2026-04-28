# Wait strategies

A container is "started" the moment Docker says so, but it's almost
never **ready** at that point. A wait strategy is what `with_container`
polls until your container is genuinely usable.

The default for a fresh `container.new(...)` is `wait.none()` - no
wait. For real services you almost always want a real probe.

## The basics

```gleam
import testcontainer/wait

container.new("redis:7-alpine")
|> container.wait_for(wait.log("Ready to accept connections"))
```

`with_container` starts the container, then polls the strategy at the
configured interval (default 1 s) until it succeeds or the timeout
(default 60 s) elapses. On timeout it returns
`Error(WaitTimedOut(strategy_description, elapsed_ms))` - `elapsed_ms`
is the actual wall-clock time, not the configured timeout.

## All the strategies

### `wait.none()`

Succeeds immediately. The default.

### `wait.log(message)` / `wait.log_times(message, n)`

Reads the container's combined stdout/stderr stream and counts how
many times `message` appears. Useful when an image prints a clear
"ready" line:

```gleam
wait.log("database system is ready to accept connections")
wait.log_times("listening on port", 2)
```

### `wait.port(int)`

TCP-connects to the host-mapped port. The simplest "is it listening?"
probe.

```gleam
container.new("nginx:alpine")
|> container.expose_port(port.tcp(80))
|> container.wait_for(wait.port(80))
```

### `wait.http(port, path)` / `wait.http_with_status(port, path, status)`

GETs `path` on the host-mapped port and checks the HTTP status.

```gleam
wait.http(8080, "/health")
wait.http_with_status(8080, "/health", 204)
```

### `wait.health_check()`

Reads `Docker inspect` and waits for `State.Health.Status == "healthy"`.
The image must define a `HEALTHCHECK` for this to ever terminate.

### `wait.command(cmd)`

Runs a command inside the container via `docker exec` and waits for
exit 0. Great when no external probe is exposed:

```gleam
wait.command(["pg_isready", "-U", "postgres"])
```

### `wait.all_of([...])` / `wait.any_of([...])`

Compose strategies. `all_of` succeeds when every inner strategy
succeeds (per poll cycle); `any_of` succeeds as soon as one does.

```gleam
wait.all_of([
  wait.port(5432),
  wait.log("database system is ready"),
])
```

## Tuning

```gleam
wait.log("ready")
|> wait.with_timeout(30_000)
|> wait.with_poll_interval(500)
```

Both modifiers return a new `WaitStrategy`. Defaults are 60 s timeout
and 1 s poll.

## Tips

- Prefer **`log`** when the image prints a clean readiness line - it's
  the cheapest and most reliable probe.
- Prefer **`http`** when there's a `/health` endpoint - it actually
  exercises the server's I/O loop.
- Use **`all_of`** when both port-open and a log line are independent
  signals; it catches more flaky-startup bugs than either alone.
- Use **`command`** for processes that are healthy purely from inside
  (cron-style daemons, queues without an external port).
