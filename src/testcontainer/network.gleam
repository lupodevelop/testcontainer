import gleam/erlang/process
import gleam/result

import testcontainer/error
import testcontainer/internal/docker

/// A Docker bridge network. Construct with `create/1` (or `with_network/2`
/// for automatic cleanup) and pass the name to `container.on_network/2`.
pub opaque type Network {
  Network(id: String, name: String)
}

/// Creates a new bridge network with the given name.
pub fn create(name: String) -> Result(Network, error.Error) {
  use id <- result.try(docker.create_network(name))
  Ok(Network(id, name))
}

/// Removes a network created via `create/1`.
pub fn remove(network: Network) -> Result(Nil, error.Error) {
  docker.remove_network(network.id)
}

/// Creates a network, runs `body/1`, then removes it. Cleanup runs even if
/// `body/1` returns an error or the caller process crashes (a linked guard
/// process performs the removal asynchronously on caller down).
///
///   use net <- network.with_network("test-net")
///
pub fn with_network(
  name: String,
  body: fn(Network) -> Result(a, error.Error),
) -> Result(a, error.Error) {
  use #(net, guard) <- result.try(create_guarded(name))
  let body_result = body(net)
  process.send(guard, GuardStop)
  let remove_result = remove(net)
  case body_result, remove_result {
    Ok(_), Error(rm_e) -> Error(rm_e)
    _, _ -> body_result
  }
}

/// The network's name (as passed to `create/1`).
pub fn name(network: Network) -> String {
  network.name
}

/// The Docker-assigned network id.
pub fn id(network: Network) -> String {
  network.id
}

// ---------------------------------------------------------------------------
// Guarded creation
// ---------------------------------------------------------------------------

type GuardEvent {
  GuardStop
  ParentDown
}

// Spawns a linked process that creates the network, sends the result back,
// and (on success) waits for either GuardStop (clean exit) or a trapped
// caller-exit signal. On caller crash it fires the network removal in a
// detached process so the BEAM can shut down cleanly without blocking on
// Docker.
fn create_guarded(
  name: String,
) -> Result(#(Network, process.Subject(GuardEvent)), error.Error) {
  let startup_subject: process.Subject(
    Result(#(Network, process.Subject(GuardEvent)), error.Error),
  ) = process.new_subject()

  process.spawn(fn() {
    process.trap_exits(True)
    let guard = process.new_subject()
    case create(name) {
      Ok(net) -> {
        process.send(startup_subject, Ok(#(net, guard)))
        guard_loop(net.id, guard)
      }
      Error(e) -> process.send(startup_subject, Error(e))
    }
  })

  let selector = process.new_selector() |> process.select(startup_subject)
  process.selector_receive_forever(selector)
}

fn guard_loop(id: String, subject: process.Subject(GuardEvent)) -> Nil {
  let selector =
    process.new_selector()
    |> process.select(subject)
    |> process.select_trapped_exits(fn(_) { ParentDown })
  case process.selector_receive_forever(selector) {
    GuardStop -> Nil
    ParentDown -> {
      // Fire-and-forget remove; transport enforces its own per-call timeouts.
      process.spawn(fn() {
        let _ = docker.remove_network(id)
        Nil
      })
      Nil
    }
  }
}
