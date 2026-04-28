import testcontainer/error
import testcontainer/network

/// A `Stack(output)` represents a Docker network whose lifetime spans
/// multiple containers. The companion entry point is
/// `testcontainer.with_stack/2`.
///
/// ## Recommended pattern
///
/// `output` is typically just `Network` - the build function returns the
/// running network unchanged, and the caller nests `with_container` or
/// `with_formula` calls inside the `with_stack` body so that each container
/// is cleaned up by its own guard before the network is removed:
///
///     use net <- testcontainer.with_stack(
///       testcontainer.stack("app-test-net", fn(n) { Ok(n) }),
///     )
///     use pg <- testcontainer.with_formula(
///       postgres.new() |> postgres.on_network(net) |> postgres.formula(),
///     )
///     // ...
///
/// ## Note on advanced builders
///
/// The build function can return any `output`, but it must be a value that
/// is still meaningful after the function returns. Containers started via
/// `with_container`/`with_formula` are stopped before their wrapping `use`
/// returns, so a record carrying live `Container` handles is **not** a
/// valid `output`. Either return `Network` (or a static record derived
/// from it) and nest the lifecycle calls in the `with_stack` body, or call
/// `testcontainer.start/1` directly inside `run` and accept manual
/// teardown responsibility.
pub opaque type Stack(output) {
  Stack(
    network_name: String,
    run: fn(network.Network) -> Result(output, error.Error),
  )
}

/// Builds a `Stack` with the given network name and a function that, given
/// the running `Network`, returns the typed output the test will consume.
///
///   testcontainer.stack("app-test-net", fn(net) { Ok(net) })
pub fn new(
  network_name: String,
  run: fn(network.Network) -> Result(output, error.Error),
) -> Stack(output) {
  Stack(network_name, run)
}

@internal
pub fn name(s: Stack(output)) -> String {
  s.network_name
}

@internal
pub fn run(
  s: Stack(output),
  net: network.Network,
) -> Result(output, error.Error) {
  s.run(net)
}
