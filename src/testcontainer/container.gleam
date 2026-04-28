import cowl

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

import testcontainer/error
import testcontainer/port
import testcontainer/wait

/// A volume mount applied to a container. Build with `bind_mount/2`,
/// `readonly_bind_mount/2`, or `tmpfs/1`.
pub opaque type Volume {
  BindMount(host_path: String, container_path: String, read_only: Bool)
  TmpfsMount(container_path: String)
}

/// Creates a read-write bind mount from `host_path` to `container_path`.
pub fn bind_mount(host_path: String, container_path: String) -> Volume {
  BindMount(host_path, container_path, False)
}

/// Creates a read-only bind mount.
pub fn readonly_bind_mount(
  host_path: String,
  container_path: String,
) -> Volume {
  BindMount(host_path, container_path, True)
}

/// Creates an in-memory tmpfs mount at `container_path`.
pub fn tmpfs(container_path: String) -> Volume {
  TmpfsMount(container_path)
}

/// Internal - used by `internal/docker.gleam` to project a Volume into the
/// shape expected by the Docker Engine API. Returns:
/// - `Ok(Ok(#(host, container, read_only)))` for a bind mount,
/// - `Ok(Error(container))` for a tmpfs mount.
@internal
pub fn volume_kind(v: Volume) -> Result(#(String, String, Bool), String) {
  case v {
    BindMount(h, c, ro) -> Ok(#(h, c, ro))
    TmpfsMount(c) -> Error(c)
  }
}

/// Immutable description of a container to be started.
/// Build it via `new/1` and the `with_*` modifiers, then pass to
/// `testcontainer.start/1` or `testcontainer.with_container/2`.
pub opaque type ContainerSpec {
  ContainerSpec(
    image: String,
    env: List(#(String, cowl.Secret(String))),
    ports: List(port.Port),
    wait_strategy: wait.WaitStrategy,
    command: Option(List(String)),
    entrypoint: Option(List(String)),
    volumes: List(Volume),
    network: Option(String),
    name: Option(String),
    labels: List(#(String, String)),
    privileged: Bool,
  )
}

/// Creates a new spec for the given image (e.g. `"redis:7-alpine"`).
/// The default wait strategy is `wait.none/0` (no wait) - most images need
/// a real `wait_for/2` (e.g. `wait.log("ready")`) to be reliable.
pub fn new(image: String) -> ContainerSpec {
  ContainerSpec(
    image: image,
    env: [],
    ports: [],
    wait_strategy: wait.none(),
    command: None,
    entrypoint: None,
    volumes: [],
    network: None,
    name: None,
    labels: [],
    privileged: False,
  )
}

/// Adds an environment variable. The value is wrapped in a `cowl.Secret`
/// internally; use `with_secret_env/3` if you already have a Secret.
pub fn with_env(
  spec: ContainerSpec,
  key: String,
  value: String,
) -> ContainerSpec {
  ContainerSpec(
    ..spec,
    env: list.append(spec.env, [#(key, cowl.secret(value))]),
  )
}

/// Adds multiple environment variables at once.
pub fn with_envs(
  spec: ContainerSpec,
  pairs: List(#(String, String)),
) -> ContainerSpec {
  let wrapped = list.map(pairs, fn(p) { #(p.0, cowl.secret(p.1)) })
  ContainerSpec(..spec, env: list.append(spec.env, wrapped))
}

/// Adds an environment variable whose value is already a `cowl.Secret`.
pub fn with_secret_env(
  spec: ContainerSpec,
  key: String,
  value: cowl.Secret(String),
) -> ContainerSpec {
  ContainerSpec(..spec, env: list.append(spec.env, [#(key, value)]))
}

/// Exposes a single container port to the host (host port assigned dynamically).
pub fn expose_port(spec: ContainerSpec, p: port.Port) -> ContainerSpec {
  ContainerSpec(..spec, ports: list.append(spec.ports, [p]))
}

/// Exposes multiple container ports to the host.
pub fn expose_ports(spec: ContainerSpec, ps: List(port.Port)) -> ContainerSpec {
  ContainerSpec(..spec, ports: list.append(spec.ports, ps))
}

/// Sets the readiness wait strategy. The default is "no wait".
pub fn wait_for(
  spec: ContainerSpec,
  strategy: wait.WaitStrategy,
) -> ContainerSpec {
  ContainerSpec(..spec, wait_strategy: strategy)
}

/// Overrides the container's CMD.
pub fn with_command(spec: ContainerSpec, cmd: List(String)) -> ContainerSpec {
  ContainerSpec(..spec, command: Some(cmd))
}

/// Overrides the container's ENTRYPOINT.
pub fn with_entrypoint(spec: ContainerSpec, ep: List(String)) -> ContainerSpec {
  ContainerSpec(..spec, entrypoint: Some(ep))
}

/// Adds a read-write bind mount (host path → container path).
pub fn with_bind_mount(
  spec: ContainerSpec,
  host: String,
  container_path: String,
) -> ContainerSpec {
  with_volume(spec, bind_mount(host, container_path))
}

/// Adds a read-only bind mount.
pub fn with_readonly_bind(
  spec: ContainerSpec,
  host: String,
  container_path: String,
) -> ContainerSpec {
  with_volume(spec, readonly_bind_mount(host, container_path))
}

/// Mounts an in-memory tmpfs at the given path inside the container.
pub fn with_tmpfs(spec: ContainerSpec, path: String) -> ContainerSpec {
  with_volume(spec, tmpfs(path))
}

/// Adds an arbitrary `Volume` (built with `bind_mount/2`, `tmpfs/1`, …).
pub fn with_volume(spec: ContainerSpec, v: Volume) -> ContainerSpec {
  ContainerSpec(..spec, volumes: list.append(spec.volumes, [v]))
}

/// Attaches the container to the named Docker network.
pub fn on_network(spec: ContainerSpec, network: String) -> ContainerSpec {
  ContainerSpec(..spec, network: Some(network))
}

/// Assigns a fixed name to the container (otherwise Docker auto-generates one).
pub fn with_name(spec: ContainerSpec, n: String) -> ContainerSpec {
  ContainerSpec(..spec, name: Some(n))
}

/// Adds a label to the container.
pub fn with_label(
  spec: ContainerSpec,
  key: String,
  value: String,
) -> ContainerSpec {
  ContainerSpec(..spec, labels: list.append(spec.labels, [#(key, value)]))
}

/// Marks the container as privileged.
pub fn with_privileged(spec: ContainerSpec) -> ContainerSpec {
  ContainerSpec(..spec, privileged: True)
}

// --- ContainerSpec accessors ---

pub fn image(spec: ContainerSpec) -> String {
  spec.image
}

pub fn env(spec: ContainerSpec) -> List(#(String, cowl.Secret(String))) {
  spec.env
}

pub fn ports(spec: ContainerSpec) -> List(port.Port) {
  spec.ports
}

pub fn wait_strategy(spec: ContainerSpec) -> wait.WaitStrategy {
  spec.wait_strategy
}

pub fn command(spec: ContainerSpec) -> Option(List(String)) {
  spec.command
}

pub fn entrypoint(spec: ContainerSpec) -> Option(List(String)) {
  spec.entrypoint
}

pub fn volumes(spec: ContainerSpec) -> List(Volume) {
  spec.volumes
}

pub fn network(spec: ContainerSpec) -> Option(String) {
  spec.network
}

pub fn name(spec: ContainerSpec) -> Option(String) {
  spec.name
}

pub fn labels(spec: ContainerSpec) -> List(#(String, String)) {
  spec.labels
}

pub fn is_privileged(spec: ContainerSpec) -> Bool {
  spec.privileged
}

// --- Container (running) ---

/// A handle to a running Docker container.
/// Returned by `testcontainer.start/1`. Carries the container id,
/// gateway host, port mapping and keep-alive flag.
///
/// `port_mapping` is keyed by `(container_port, protocol)` - `protocol` is
/// always `"tcp"` or `"udp"` - so TCP and UDP ports with the same number
/// don't collide.
pub opaque type Container {
  Container(
    id: String,
    gateway_host: String,
    port_mapping: dict.Dict(#(Int, String), Int),
    keep: Bool,
    stop_timeout_sec: Int,
  )
}

/// Internal constructor - used by `testcontainer.start/1`. The
/// `stop_timeout_sec` is captured at start time so `stop/1` and the
/// crash-cleanup guard do not re-read the env on every call.
@internal
pub fn build(
  id: String,
  gateway_host: String,
  port_mapping: dict.Dict(#(Int, String), Int),
  keep: Bool,
  stop_timeout_sec: Int,
) -> Container {
  Container(id, gateway_host, port_mapping, keep, stop_timeout_sec)
}

/// Internal mutator - used by `testcontainer.start_and_keep/1` to force
/// the keep flag regardless of `TESTCONTAINERS_KEEP`.
@internal
pub fn with_keep(c: Container, keep: Bool) -> Container {
  Container(..c, keep: keep)
}

/// Internal accessor - used by `testcontainer.stop/1` and the crash-cleanup
/// guard to know how long to wait for graceful shutdown before SIGKILL.
@internal
pub fn stop_timeout_sec(c: Container) -> Int {
  c.stop_timeout_sec
}

/// Returns the Docker container id.
pub fn id(c: Container) -> String {
  c.id
}

/// Returns the host that the test runner should use to reach the
/// container's mapped ports (typically the bridge gateway IP, or
/// the value of `TESTCONTAINERS_HOST_OVERRIDE`).
pub fn host(c: Container) -> String {
  c.gateway_host
}

/// Whether this container should be kept alive after the test
/// (`TESTCONTAINERS_KEEP=true` or `start_and_keep/1`).
pub fn keep(c: Container) -> Bool {
  c.keep
}

/// Returns the host port that maps to the given container port,
/// or `PortNotMapped` if the port is not exposed.
pub fn host_port(c: Container, p: port.Port) -> Result(Int, error.Error) {
  let n = port.number(p)
  let proto = port.protocol(p)
  case dict.get(c.port_mapping, #(n, proto)) {
    Ok(hp) -> Ok(hp)
    Error(Nil) -> Error(error.PortNotMapped(n))
  }
}

/// Builds a URL for the given container port using the configured scheme,
/// host, and mapped host port (e.g. `"http://127.0.0.1:32768"`).
pub fn mapped_url(
  c: Container,
  p: port.Port,
  scheme: String,
) -> Result(String, error.Error) {
  case host_port(c, p) {
    Ok(hp) -> Ok(scheme <> "://" <> host(c) <> ":" <> int.to_string(hp))
    Error(e) -> Error(e)
  }
}
