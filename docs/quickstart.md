# Quickstart

5-minute tour. By the end of this page, you'll start a real container
in a test, talk to it, and let `testcontainer` clean it up for you.

## Prerequisites

- Gleam ≥ 1.1
- A running local Docker daemon (Docker Desktop, Colima, OrbStack,
  plain `dockerd` on Linux - all fine)

## Install

```sh
gleam add testcontainer
```

## Hello, Redis

```gleam
import gleam/int
import testcontainer
import testcontainer/container
import testcontainer/port
import testcontainer/wait

pub fn redis_test() {
  use redis <- testcontainer.with_container(
    container.new("redis:7-alpine")
    |> container.expose_port(port.tcp(6379))
    |> container.wait_for(wait.log("Ready to accept connections")),
  )

  let assert Ok(host_port) = container.host_port(redis, port.tcp(6379))
  let _url = "redis://127.0.0.1:" <> int.to_string(host_port)
  // hand `_url` to your Redis client
  Ok(Nil)
}
```

What just happened:

1. `container.new` builds an immutable spec.
2. `with_container` pulls the image (if missing), starts the
   container, polls the wait strategy until it succeeds, then runs
   your body.
3. The library spawns a **linked guard process**. If your test
   panics or the BEAM kills the parent, the guard stops & removes the
   container. No dangling resources, no Ryuk, no shell scripts.
4. When your body returns, the container is stopped and removed before
   `with_container` hands the result back.

## A quick exec

```gleam
use c <- testcontainer.with_container(
  container.new("alpine:3.18")
  |> container.with_command(["sh", "-c", "sleep 30"]),
)

use result <- result.try(testcontainer.exec(c, ["uname", "-a"]))
io.println(result.stdout)
Ok(Nil)
```

`exec` returns `ExecResult` with `exit_code`, `stdout`, `stderr` -
stderr is split out for you (Docker streams them multiplexed; the
library demuxes).

## Custom error types

Most projects already have an `AppError`. Don't fight it:

```gleam
import testcontainer/error

type AppError {
  Container(error.Error)
  AppLogic(String)
}

use c <- testcontainer.with_container_mapped(
  spec,
  fn(e) { Container(e) },
)
// body returns Result(_, AppError)
```

## What's next

- [Wait strategies](wait-strategies.md) - `log`, `port`, `http`,
  `command`, `health_check`, `all_of`, `any_of`
- [Formule](formule.md) - typed builders for Postgres, Redis & more
- [Networks & Stacks](networks-and-stacks.md) - multiple containers
  on a shared bridge
- [Configuration](configuration.md) - `DOCKER_HOST`,
  `TESTCONTAINERS_KEEP`, registry auth
