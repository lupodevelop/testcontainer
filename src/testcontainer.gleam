import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

import testcontainer/container
import testcontainer/error
import testcontainer/exec
import testcontainer/formula
import testcontainer/internal/config
import testcontainer/internal/docker
import testcontainer/internal/wait_runner
import testcontainer/network
import testcontainer/stack as stack_mod

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Starts a container described by `spec` and returns it.
/// The caller is responsible for calling `stop/1` when done.
/// For automatic cleanup, prefer `with_container/2`.
pub fn start(
  spec: container.ContainerSpec,
) -> Result(container.Container, error.Error) {
  start_internal(spec)
}

fn start_internal(
  spec: container.ContainerSpec,
) -> Result(container.Container, error.Error) {
  let cfg = config.load()
  let keep = cfg.keep_containers
  let stop_timeout = cfg.stop_timeout_sec
  let gateway = resolve_gateway(cfg.host_override)

  use _ <- result.try(docker.ping())

  let image = container.image(spec)
  use _ <- result.try(case cfg.pull_policy {
    config.Never ->
      case docker.image_exists(image) {
        True -> Ok(Nil)
        False ->
          Error(error.ImagePullFailed(
            image,
            "TESTCONTAINERS_PULL_POLICY=never and image not present locally",
          ))
      }
    config.IfMissing ->
      case docker.image_exists(image) {
        True -> Ok(Nil)
        False -> docker.pull_image(image, cfg.registry_auth)
      }
    config.Always -> docker.pull_image(image, cfg.registry_auth)
  })

  use id <- result.try(docker.create_container(spec))

  use _ <- result.try(
    docker.start_container(id)
    |> result.map_error(fn(e) {
      let _ = docker.remove_container(id)
      e
    }),
  )

  let strategy = container.wait_strategy(spec)
  use _ <- result.try(
    wait_runner.run(strategy, id, gateway)
    |> result.map_error(fn(e) {
      // Container started but wait failed - clean it up before propagating.
      let _ = docker.stop_container(id, stop_timeout)
      let _ = docker.remove_container(id)
      e
    }),
  )

  use inspect <- result.try(
    docker.inspect_container(id)
    |> result.map_error(fn(e) {
      let _ = docker.stop_container(id, stop_timeout)
      let _ = docker.remove_container(id)
      e
    }),
  )
  use ports <- result.try(
    parse_port_mapping(id, inspect)
    |> result.map_error(fn(e) {
      let _ = docker.stop_container(id, stop_timeout)
      let _ = docker.remove_container(id)
      e
    }),
  )
  Ok(container.build(id, gateway, ports, keep, stop_timeout))
}

/// Stops and removes a container.
/// When `TESTCONTAINERS_KEEP` is set (or the container was started via
/// `start_and_keep/1`) the container is left running for manual
/// inspection. Use `force_stop/1` to tear it down regardless.
pub fn stop(c: container.Container) -> Result(Nil, error.Error) {
  case container.keep(c) {
    True -> Ok(Nil)
    False -> force_stop(c)
  }
}

/// Stops and removes a container ignoring the keep flag. Useful to
/// programmatically tear down containers that were started with
/// `start_and_keep/1` or under `TESTCONTAINERS_KEEP=true`.
pub fn force_stop(c: container.Container) -> Result(Nil, error.Error) {
  let id = container.id(c)
  use _ <- result.try(docker.stop_container(id, container.stop_timeout_sec(c)))
  docker.remove_container(id)
}

/// Starts a container, runs `body/1`, then stops and removes it.
/// A linked guard process ensures cleanup also runs if the caller crashes.
///
///   use c <- testcontainer.with_container(spec)
///
pub fn with_container(
  spec: container.ContainerSpec,
  body: fn(container.Container) -> Result(a, error.Error),
) -> Result(a, error.Error) {
  use #(c, guard) <- result.try(start_guarded(spec))
  let body_result = body(c)
  combine(body_result, cleanup(c, guard))
}

/// Like `with_container/2` but maps the library's error type into a custom
/// error type before propagating.
///
///   use c <- testcontainer.with_container_mapped(
///     spec,
///     fn(e) { MyError.Container(e) },
///   )
///
pub fn with_container_mapped(
  spec: container.ContainerSpec,
  map_error: fn(error.Error) -> e,
  body: fn(container.Container) -> Result(a, e),
) -> Result(a, e) {
  use #(started, guard) <- result.try(
    start_guarded(spec) |> result.map_error(map_error),
  )
  let body_result = body(started)
  combine(body_result, cleanup(started, guard) |> result.map_error(map_error))
}

/// Creates a Docker network, runs `body/1`, then removes it. Cleanup runs
/// even if `body/1` returns an error. Re-export of `network.with_network/2`
/// for one-import ergonomics.
///
///   use net <- testcontainer.with_network("test-net")
///
pub fn with_network(
  name: String,
  body: fn(network.Network) -> Result(a, error.Error),
) -> Result(a, error.Error) {
  network.with_network(name, body)
}

/// Builds a `Stack(output)` - a network plus a typed multi-container build
/// function. See `with_stack/2`.
pub fn stack(
  network_name: String,
  build: fn(network.Network) -> Result(output, error.Error),
) -> stack_mod.Stack(output) {
  stack_mod.new(network_name, build)
}

/// Creates the stack's network, runs the stack's build function to produce
/// a typed `output`, then runs `body/1` against that output. The network is
/// torn down after `body/1` returns. The recommended pattern is to let the
/// stack provide a `Network` and nest `with_container` / `with_formula`
/// calls inside `body`, so each container is cleaned up by its own guard
/// before the network is removed:
///
///   use net <- testcontainer.with_stack(
///     testcontainer.stack("app-test-net", fn(n) { Ok(n) }),
///   )
///   use pg <- testcontainer.with_formula(
///     postgres.new() |> postgres.on_network(net) |> postgres.formula(),
///   )
///   // ...
///
/// See `testcontainer/stack.{Stack}` for notes on advanced builders.
pub fn with_stack(
  s: stack_mod.Stack(output),
  body: fn(output) -> Result(a, error.Error),
) -> Result(a, error.Error) {
  network.with_network(stack_mod.name(s), fn(net) {
    use out <- result.try(stack_mod.run(s, net))
    body(out)
  })
}

/// Executes a command inside a running container.
pub fn exec(
  c: container.Container,
  cmd: List(String),
) -> Result(exec.ExecResult, error.Error) {
  docker.exec_container(container.id(c), cmd)
}

/// Returns the combined stdout+stderr log output of a running container
/// (full log).
pub fn logs(c: container.Container) -> Result(String, error.Error) {
  docker.container_logs(container.id(c), None)
}

/// Like `logs/1` but returns only the last `n` lines.
pub fn logs_tail(
  c: container.Container,
  n: Int,
) -> Result(String, error.Error) {
  docker.container_logs(container.id(c), Some(n))
}

/// Copies a file from the host filesystem into a running container.
/// `host_path` must be an absolute path to a readable file on the host.
/// `container_path` is the absolute destination path inside the container.
///
///   use _ <- result.try(testcontainer.copy_file_to(c, "/host/init.sql", "/tmp/init.sql"))
///
pub fn copy_file_to(
  c: container.Container,
  host_path: String,
  container_path: String,
) -> Result(Nil, error.Error) {
  docker.copy_file_to(container.id(c), host_path, container_path)
}

/// Starts a container using a `Formula`, extracts the typed output, then
/// calls `body/1`. Lifecycle and cleanup work exactly like `with_container/2`.
///
///   use pg <- testcontainer.with_formula(postgres.formula(config))
///   // pg :: PostgresContainer
///
pub fn with_formula(
  f: formula.Formula(output),
  body: fn(output) -> Result(a, error.Error),
) -> Result(a, error.Error) {
  use #(c, guard) <- result.try(start_guarded(formula.spec(f)))
  let body_result = result.try(formula.extract(f, c), body)
  combine(body_result, cleanup(c, guard))
}

/// Acquires a resource using a `StandaloneFormula`, calls `body/1`, then
/// releases the resource. Release always runs even if body returns an error.
/// If body succeeded but release failed, the release error is surfaced.
///
///   use stack <- testcontainer.with_standalone_formula(compose_formula)
///
pub fn with_standalone_formula(
  f: formula.StandaloneFormula(output, err),
  body: fn(output) -> Result(a, err),
) -> Result(a, err) {
  use output <- result.try(formula.standalone_acquire(f))
  let body_result = body(output)
  combine(body_result, formula.standalone_release(f))
}

// ---------------------------------------------------------------------------
// Lifecycle helpers
// ---------------------------------------------------------------------------

// Send GuardStop and synchronously stop the container.
fn cleanup(
  c: container.Container,
  guard: process.Subject(GuardEvent),
) -> Result(Nil, error.Error) {
  process.send(guard, GuardStop)
  stop(c)
}

// Body's outcome wins. If body succeeded but cleanup failed, surface the
// cleanup failure so the caller knows the container was leaked.
fn combine(body: Result(a, e), cleanup: Result(Nil, e)) -> Result(a, e) {
  case body, cleanup {
    Ok(_), Error(e) -> Error(e)
    _, _ -> body
  }
}

/// Starts a container and forces the keep flag, so it will NOT be removed
/// by `stop/1` even if `TESTCONTAINERS_KEEP=false`. Useful for inspection
/// and debugging from a REPL.
pub fn start_and_keep(
  spec: container.ContainerSpec,
) -> Result(container.Container, error.Error) {
  use #(c, guard) <- result.try(start_guarded(spec))
  process.send(guard, GuardStop)
  Ok(container.with_keep(c, True))
}

// ---------------------------------------------------------------------------
// Guard process
// ---------------------------------------------------------------------------
//
// GuardStop  - parent finished normally; guard exits, no cleanup needed.
// ParentDown - parent crashed; guard stops and removes the container.

type GuardEvent {
  GuardStop
  ParentDown
}

fn start_guarded(
  spec: container.ContainerSpec,
) -> Result(#(container.Container, process.Subject(GuardEvent)), error.Error) {
  let startup_subject: process.Subject(
    Result(#(container.Container, process.Subject(GuardEvent)), error.Error),
  ) = process.new_subject()

  // process.spawn/1 from gleam_erlang is `proc_lib:spawn_link/1` - the link
  // to the caller is established atomically with the spawn, so the guard is
  // notified of any caller crash even during startup.
  process.spawn(fn() {
    process.trap_exits(True)
    let guard = process.new_subject()
    case start_internal(spec) {
      Ok(c) -> {
        process.send(startup_subject, Ok(#(c, guard)))
        guard_loop(
          container.id(c),
          guard,
          container.keep(c),
          container.stop_timeout_sec(c),
        )
      }
      Error(e) -> process.send(startup_subject, Error(e))
    }
  })
  let selector = process.new_selector() |> process.select(startup_subject)
  process.selector_receive_forever(selector)
}

fn guard_loop(
  id: String,
  subject: process.Subject(GuardEvent),
  keep: Bool,
  stop_timeout: Int,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_trapped_exits(fn(_) { ParentDown })
  case process.selector_receive_forever(selector) {
    GuardStop -> Nil
    ParentDown ->
      case keep {
        True -> Nil
        False -> {
          // Fire-and-forget: guard exits immediately; cleanup runs async.
          // The transport layer enforces per-call timeouts (connect 5 s, recv 30 s).
          process.spawn(fn() {
            let _ = docker.stop_container(id, stop_timeout)
            let _ = docker.remove_container(id)
            Nil
          })
          Nil
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// The "Gateway" field from inspect is the bridge IP - unreachable from the
// host on macOS / WSL2 Docker Desktop. Mapped ports are bound to 127.0.0.1
// on every supported platform, so localhost is the safe default. Users on
// remote/CI Docker hosts can override with TESTCONTAINERS_HOST_OVERRIDE.
fn resolve_gateway(host_override: Option(String)) -> String {
  case host_override {
    Some(h) -> h
    None -> "127.0.0.1"
  }
}

fn parse_port_mapping(
  container_id: String,
  inspect_json: String,
) -> Result(dict.Dict(#(Int, String), Int), error.Error) {
  let ports_decoder =
    decode.at(
      ["NetworkSettings", "Ports"],
      decode.dict(
        decode.string,
        decode.optional(decode.list(port_binding_decoder())),
      ),
    )

  use decoded <- result.try(
    json.parse(inspect_json, ports_decoder)
    |> result.map_error(fn(_) {
      error.PortMappingParseFailed(
        container_id,
        "unable to decode inspect NetworkSettings.Ports payload",
      )
    }),
  )
  use mappings <- result.try(
    decoded
    |> dict.to_list
    |> list.try_map(entry_to_mapping)
    |> result.map_error(fn(reason) {
      error.PortMappingParseFailed(container_id, reason)
    }),
  )
  let bound =
    list.filter_map(mappings, fn(o) {
      case o {
        Some(v) -> Ok(v)
        None -> Error(Nil)
      }
    })
  Ok(dict.from_list(bound))
}

// Image `EXPOSE` directives surface every declared port in
// `NetworkSettings.Ports`, including ones the user never requested. Those
// entries have a `null` binding list. Treat them as "not requested" and skip,
// rather than failing the whole inspect — only `expose_port`-requested ports
// matter for `host_port/2` lookups.
fn entry_to_mapping(
  entry: #(String, Option(List(PortBinding))),
) -> Result(Option(#(#(Int, String), Int)), String) {
  let #(spec, bindings) = entry
  use key <- result.try(case parse_port_spec(spec) {
    Some(parsed) -> Ok(parsed)
    None -> Error("invalid inspect port key: " <> spec)
  })
  case bindings {
    None -> Ok(None)
    Some(bs) ->
      case pick_binding(bs) {
        Some(host_port) -> Ok(Some(#(key, host_port)))
        None -> Error("invalid host port binding in inspect for key: " <> spec)
      }
  }
}

// Prefer IPv4 (HostIp "" or "0.0.0.0") over IPv6 (::), then take the first.
fn pick_binding(bs: List(PortBinding)) -> Option(Int) {
  list.find(bs, fn(b: PortBinding) { b.host_ip == "0.0.0.0" || b.host_ip == "" })
  |> result.try_recover(fn(_) { list.first(bs) })
  |> result.try(fn(b) { int.parse(b.host_port) })
  |> option_from_result
}

fn option_from_result(r: Result(a, b)) -> Option(a) {
  case r {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

type PortBinding {
  PortBinding(host_ip: String, host_port: String)
}

fn port_binding_decoder() -> decode.Decoder(PortBinding) {
  use host_ip <- decode.field("HostIp", decode.string)
  use host_port <- decode.field("HostPort", decode.string)
  decode.success(PortBinding(host_ip, host_port))
}

// Parse a Docker "Ports" key (e.g. "5432/tcp", "53/udp") into
// (port_number, protocol).
fn parse_port_spec(port_spec: String) -> Option(#(Int, String)) {
  case string.split(port_spec, "/") {
    [p, proto] ->
      case int.parse(p) {
        Ok(i) -> Some(#(i, proto))
        Error(_) -> None
      }
    [p] ->
      case int.parse(p) {
        Ok(i) -> Some(#(i, "tcp"))
        Error(_) -> None
      }
    _ -> None
  }
}
