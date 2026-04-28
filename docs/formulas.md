# Formulas: your container's shipping documents

> _"In dogana non passi col container nudo: passi con i documenti."_
>
> _"At customs you don't pass with a naked container: you pass with the
> paperwork."_

A **Formula** is your container's **bill of lading**: a pre-packaged
spec, with label, customs declaration and typed receipt. Instead of
writing env vars, ports, wait strategy and then rebuilding the
connection URL by hand every time, a formula hands it to you already
compiled, signed and stamped.

In less romantic terms: a `Formula(output)` pairs a `ContainerSpec`
with a typed extraction function. When the core starts the container,
it calls the extractor and returns a value of a specific type (e.g.
`PostgresContainer` with `connection_url`, `host`, `port`, `database`,
`username` already filled in) instead of a generic `Container`.

```gleam
use pg <- testcontainer.with_formula(
  postgres.new()
  |> postgres.with_database("myapp_test")
  |> postgres.with_password("secret")
  |> postgres.formula(),
)

// pg.connection_url
// "postgresql://postgres:secret@127.0.0.1:54321/myapp_test"
```

## Why call them "formulas"

The term evokes alchemists more than customs offices. The key point is
that a Formula is **prescriptive**: it says "this is the official
recipe for serving Postgres reliably". You use it as a base and add
the overrides you need. All the bureaucracy (right env vars, wait
strategy that actually works, healthcheck, URL composer) lives inside
the formula. You sign it.

## Where they live

The core package (`testcontainer`) **knows nothing** about Postgres,
Redis or Kafka. It only defines the `Formula(output)` type and the
`with_formula` entry point. The actual formulas live in a separate
package:

```sh
gleam add testcontainer_formulas
```

```gleam
import testcontainer_formulas/postgres
import testcontainer_formulas/redis
```

## The three levels of customization

### Level 1: Builder (common case)

Sensible defaults, override only what changes:

```gleam
postgres.new()
|> postgres.with_database("myapp_test")
|> postgres.with_username("app")
|> postgres.with_password("secret")
|> postgres.formula()
```

### Level 2: Custom image

Swap only the image, keep everything else:

```gleam
postgres.new()
|> postgres.with_image("registry.mycompany.com/postgres:hardened-16")
|> postgres.formula()
```

### Level 3: No formula

When you're overriding everything, it's more honest to start from
`container.new`. No formula, no rich type, just `Container`:

```gleam
let spec =
  container.new("bitnami/postgresql:16")
  |> container.expose_port(port.tcp(5432))
  |> container.with_env("POSTGRESQL_PASSWORD", "secret")
  |> container.wait_for(wait.port(5432))

use c <- testcontainer.with_container(spec)
// build the URL yourself
```

## Writing a formula

A formula is a single Gleam file. The skeleton:

```gleam
import cowl
import gleam/option.{type Option, None, Some}
import gleam/result

import testcontainer/container
import testcontainer/formula
import testcontainer/network
import testcontainer/port
import testcontainer/wait

pub type FooContainer {
  FooContainer(container: container.Container, url: String, ...)
}

pub opaque type FooConfig {
  FooConfig(image: String, ...)
}

pub fn new() -> FooConfig { ... }
pub fn with_version(c: FooConfig, v: String) -> FooConfig { ... }
// ...other builders...

pub fn formula(c: FooConfig) -> formula.Formula(FooContainer) {
  let spec =
    container.new(c.image)
    |> container.expose_port(port.tcp(c.port))
    |> container.wait_for(wait.log("ready"))

  formula.new(spec, fn(running) {
    use p <- result.try(container.host_port(running, port.tcp(c.port)))
    Ok(FooContainer(
      container: running,
      url: "foo://" <> container.host(running) <> ":" <> int.to_string(p),
    ))
  })
}
```

All you need is `formula.new(spec, extract)`. The core does the rest.

## Available formulas

- `testcontainer_formulas/postgres`
- `testcontainer_formulas/redis`
- `testcontainer_formulas/mysql`
- `testcontainer_formulas/rabbitmq`
- `testcontainer_formulas/mongo`

## Formula Builder (Astro)

A visual builder lives in `formula-builder/` for composing advanced
blocks and generating ready-to-paste Gleam snippets.

Main features:

- built-in templates for existing formulas (`postgres`, `redis`,
  `mysql`, `rabbitmq`, `mongo`)
- `Custom formula module` block for new services (e.g. Kafka) with
  configurable import, alias and constructor
- `Formula` mode (typed output) and `Container` mode (full control)
- per-block configuration for image, env, labels, wait strategy,
  script, entrypoint, exposed ports and custom pipeline
- Docker Hub public image checker (tag existence) with fallback link
  to the Docker Hub tag page when the API is unreachable from the
  browser
- explicit Vim mode (button toggle or `Ctrl+G`), with input
  protection: `Esc` exits the text field

Local run:

```sh
cd formula-builder
npm install
npm run dev
```

Static build:

```sh
npm run build
```

Coming: kafka, localstack, elasticsearch.
See the [roadmap](../ROADMAP.md).
