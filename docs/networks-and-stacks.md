# Networks & Stacks

When two containers need to talk - your app under test plus its
database, your producer plus its broker - they have to share a
Docker bridge network. `testcontainer` gives you two primitives:
**`with_network`** for the simple case and **`Stack`** for the typed
multi-container case.

## `with_network` - single bridge

```gleam
import testcontainer
import testcontainer/container
import testcontainer/network

use net <- testcontainer.with_network("test-net")

use server <- testcontainer.with_container(
  container.new("alpine:3.18")
  |> container.with_name("server")
  |> container.on_network(network.name(net))
  |> container.with_command(["sh", "-c", "sleep 30"]),
)

use client <- testcontainer.with_container(
  container.new("alpine:3.18")
  |> container.on_network(network.name(net))
  |> container.with_command(["sh", "-c", "sleep 30"]),
)

// "server" is reachable from "client" by name on `net`
testcontainer.exec(client, ["ping", "-c", "1", "server"])
```

Cleanup ordering: each `with_container` cleans its container before
its `use` returns; `with_network` removes the network last.

## `Stack` - typed multi-container

`Stack(output)` adds a typed network builder that survives across
containers. The recommended pattern is to let the stack provide the
network and nest `with_container` / `with_formula` calls inside the
`with_stack` body:

```gleam
use net <- testcontainer.with_stack(
  testcontainer.stack("app-test-net", fn(n) { Ok(n) }),
)

use pg <- testcontainer.with_formula(
  postgres.new()
  |> postgres.on_network(net)
  |> postgres.formula(),
)

use cache <- testcontainer.with_formula(
  redis.new()
  |> redis.on_network(net)
  |> redis.formula(),
)

// pg.connection_url, cache.url usable here
```

## Stack riutilizzabile

Wrap the whole pattern once and call it from every test:

```gleam
import testcontainer
import testcontainer/error
import testcontainer_formulas/postgres
import testcontainer_formulas/redis

pub fn full_stack(
  body: fn(postgres.PostgresContainer, redis.RedisContainer)
    -> Result(a, error.Error),
) -> Result(a, error.Error) {
  use net <- testcontainer.with_stack(
    testcontainer.stack("test-net", fn(n) { Ok(n) }),
  )
  use pg <- testcontainer.with_formula(
    postgres.new() |> postgres.on_network(net) |> postgres.formula(),
  )
  use cache <- testcontainer.with_formula(
    redis.new() |> redis.on_network(net) |> redis.formula(),
  )
  body(pg, cache)
}

pub fn user_signup_test() {
  use pg, cache <- full_stack()
  // ...
}
```

## ⚠️ Footgun: the typed-output stack

`Stack(output)` is parametric so the build function can return any
`output`. **Don't return live `Container` handles** from there: those
are managed by their own `with_container` / `with_formula` guards
which clean them up before the build function returns. Keep the
build function returning `Network` (or a static record derived from
it) and nest the lifecycle inside the `with_stack` body.

If you genuinely need to start something inside `run` and keep it
alive, call `testcontainer.start/1` directly - and accept that you
own the manual teardown.
