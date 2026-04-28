<p align="center">
  <img src="https://raw.githubusercontent.com/lupodevelop/testcontainer/main/assets/img/logo.png" alt="Pago, the paguro mascot, carrying a Docker container on his shell" width="220">
</p>

<h1 align="center">testcontainer</h1>

<p align="center">
  <a href="https://hex.pm/packages/testcontainer"><img src="https://img.shields.io/hexpm/v/testcontainer?color=ffaff3" alt="Hex Package"></a>
  <a href="https://hexdocs.pm/testcontainer/"><img src="https://img.shields.io/badge/hex-docs-ffaff3" alt="Hex Docs"></a>
  <a href="https://github.com/lupodevelop/testcontainer/actions/workflows/test.yml"><img src="https://github.com/lupodevelop/testcontainer/actions/workflows/test.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/hexpm/l/testcontainer?color=blue" alt="License"></a>
  <a href="https://gleam.run"><img src="https://img.shields.io/badge/made%20with-gleam-ffaff3?logo=gleam" alt="Made with Gleam"></a>
</p>

> The hermit-crab way to run Docker containers in your Gleam tests.
> Meet **Pago**, your paguro mascot. He carries the container so you don't have to.

A small, type-safe Gleam library for spinning up real Docker containers
from your **tests** and **dev tooling**. Start a Postgres, run a query,
shut it down. Typed lifecycle and automatic cleanup even if your test
process crashes (except abrupt VM termination, e.g. `kill -9`).

```gleam
use redis <- testcontainer.with_container(
  container.new("redis:7-alpine")
  |> container.expose_port(port.tcp(6379))
  |> container.wait_for(wait.log("Ready to accept connections")),
)
let assert Ok(host_port) = container.host_port(redis, port.tcp(6379))
// connect to 127.0.0.1:host_port
```

## Why use it

- 🦀 **Crash-safe**: a linked guard process cleans containers up even
  if your test panics
- 🔒 **Type-safe lifecycle**: opaque builders, `use` syntax, errors
  always carry context
- 🐚 **Zero ceremony**: defaults that work, env vars when you need them
- 🚀 **Fast**: talks to Docker over the Unix socket directly via
  `gen_tcp` (no HTTP client to drag along)
- 📦 **Formule** ([companion package](https://hex.pm/packages/testcontainer_formulas))
  for ready-to-use Postgres / Redis / MySQL / RabbitMQ / Mongo with typed
  connection records
- 🧱 **Formulas Builder** ([testcontainer_formulas_builder](https://github.com/lupodevelop/testcontainer_formulas_builder)):
  visual block editor + codegen for `testcontainer_formulas` snippets

## Install

```sh
gleam add testcontainer
```

## Documentation

- [Quickstart](docs/quickstart.md): 5-minute tour of the API
- [Wait strategies](docs/wait-strategies.md): readiness probes that
  stay green
- [Formulas](docs/formulas.md): the customs paperwork that turns a raw
  container into a typed service
- [Formula Builder (Astro)](formula-builder/README.md): visual blocks + codegen
  for `testcontainer_formulas` snippets
- [Networks & Stacks](docs/networks-and-stacks.md): multi-container
  setups
- [Configuration](docs/configuration.md): env vars, host overrides,
  registry auth
- [Troubleshooting](docs/troubleshooting.md): common gotchas

Full API docs: <https://hexdocs.pm/testcontainer>

## License

[MIT](LICENSE).
