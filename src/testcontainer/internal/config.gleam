import cowl
import envie
import gleam/option.{type Option, None, Some}
import gleam/string

pub type PullPolicy {
  Always
  IfMissing
  Never
}

/// Credentials for pulling images from a private registry.
/// Loaded from `TESTCONTAINERS_REGISTRY_USER` and
/// `TESTCONTAINERS_REGISTRY_PASSWORD`.
pub type RegistryAuth {
  RegistryAuth(username: String, password: cowl.Secret(String))
}

pub type Config {
  Config(
    docker_host: String,
    keep_containers: Bool,
    pull_policy: PullPolicy,
    /// When set, overrides the gateway host used to reach container ports.
    /// Useful on macOS (Docker Desktop) or WSL2 where the bridge IP is not
    /// directly reachable from the host. Set via TESTCONTAINERS_HOST_OVERRIDE.
    host_override: Option(String),
    /// When set, the X-Registry-Auth header is attached to every
    /// `POST /images/create`.
    registry_auth: Option(RegistryAuth),
    /// Seconds the Docker Engine waits for graceful shutdown before sending
    /// SIGKILL during stop. Set via TESTCONTAINERS_STOP_TIMEOUT.
    stop_timeout_sec: Int,
  )
}

@internal
pub fn parse_pull_policy(value: String) -> PullPolicy {
  case string.lowercase(value) {
    "always" -> Always
    "never" -> Never
    _ -> IfMissing
  }
}

/// Loads configuration from environment variables. Always succeeds -
/// every setting has a sensible default.
pub fn load() -> Config {
  let docker_host =
    envie.get_string("DOCKER_HOST", "unix:///var/run/docker.sock")
  let keep = envie.get_bool("TESTCONTAINERS_KEEP", False)
  let pull_policy =
    parse_pull_policy(envie.get_string("TESTCONTAINERS_PULL_POLICY", "missing"))
  let host_override = case
    envie.get_string("TESTCONTAINERS_HOST_OVERRIDE", "")
  {
    "" -> None
    h -> Some(h)
  }

  let registry_auth = case
    envie.get_string("TESTCONTAINERS_REGISTRY_USER", ""),
    envie.get_string("TESTCONTAINERS_REGISTRY_PASSWORD", "")
  {
    "", _ -> None
    _, "" -> None
    user, pass -> Some(RegistryAuth(user, cowl.secret(pass)))
  }

  let stop_timeout_sec = envie.get_int("TESTCONTAINERS_STOP_TIMEOUT", 10)

  Config(
    docker_host: docker_host,
    keep_containers: keep,
    pull_policy: pull_policy,
    host_override: host_override,
    registry_auth: registry_auth,
    stop_timeout_sec: stop_timeout_sec,
  )
}
