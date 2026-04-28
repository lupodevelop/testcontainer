import gleam/int
import gleam/list
import gleam/string

/// A readiness strategy. Built via constructors (`log/1`, `port/1`, `http/2`,
/// `health_check/0`, `command/1`, `all_of/1`, `any_of/1`) and tweaked via
/// `with_timeout/2` and `with_poll_interval/2`.
pub opaque type WaitStrategy {
  WaitStrategy(base: WaitStrategyBase, timeout_ms: Int, poll_interval_ms: Int)
}

/// Internal - exposed only so the polling loop in `internal/wait_runner.gleam`
/// can pattern-match on the variants. Not part of the stable public API.
@internal
pub type WaitStrategyBase {
  /// "No wait" - succeeds immediately. Used as the default in
  /// `container.new/1`.
  ForNone
  ForLog(String, Int)
  ForPort(Int)
  ForHttp(Int, String, Int)
  ForHealthCheck
  ForCommand(List(String), Int)
  AllOf(List(WaitStrategy))
  AnyOf(List(WaitStrategy))
}

const default_timeout_ms = 60_000

const default_poll_interval_ms = 1000

fn wrap(base: WaitStrategyBase) -> WaitStrategy {
  WaitStrategy(base, default_timeout_ms, default_poll_interval_ms)
}

/// "No wait" - succeeds immediately. This is the default when a
/// `ContainerSpec` is built with `container.new/1` and no `wait_for/2`
/// is set.
pub fn none() -> WaitStrategy {
  wrap(ForNone)
}

/// Waits until the container's combined stdout/stderr stream contains the
/// given message at least once.
pub fn log(message: String) -> WaitStrategy {
  wrap(ForLog(message, 1))
}

/// Like `log/1` but waits until the message appears at least `times` times.
pub fn log_times(message: String, times: Int) -> WaitStrategy {
  wrap(ForLog(message, times))
}

/// Waits until the given (TCP) container port accepts connections from the host.
pub fn port(port: Int) -> WaitStrategy {
  wrap(ForPort(port))
}

/// Waits until an HTTP GET to the given path on the given container port
/// returns status 200.
pub fn http(port: Int, path: String) -> WaitStrategy {
  wrap(ForHttp(port, path, 200))
}

/// Like `http/2` but waits for a custom expected status code.
pub fn http_with_status(port: Int, path: String, status: Int) -> WaitStrategy {
  wrap(ForHttp(port, path, status))
}

/// Waits for Docker to report the container's HEALTHCHECK as `healthy`.
/// The image must define a HEALTHCHECK for this to terminate.
pub fn health_check() -> WaitStrategy {
  wrap(ForHealthCheck)
}

/// Runs a command inside the container and waits until it exits 0.
pub fn command(cmd: List(String)) -> WaitStrategy {
  wrap(ForCommand(cmd, 0))
}

/// Composes strategies - succeeds when ALL inner strategies succeed.
pub fn all_of(strategies: List(WaitStrategy)) -> WaitStrategy {
  wrap(AllOf(strategies))
}

/// Composes strategies - succeeds as soon as ANY inner strategy succeeds.
pub fn any_of(strategies: List(WaitStrategy)) -> WaitStrategy {
  wrap(AnyOf(strategies))
}

/// Sets the per-strategy timeout (default 60 s). Negative values are
/// clamped to 0 (the strategy times out immediately).
pub fn with_timeout(strategy: WaitStrategy, ms: Int) -> WaitStrategy {
  let safe = case ms < 0 {
    True -> 0
    False -> ms
  }
  case strategy {
    WaitStrategy(base, _, poll) -> WaitStrategy(base, safe, poll)
  }
}

/// Sets the polling interval (default 1 s). Values <= 0 are clamped to 1
/// to avoid a hot-spin loop.
pub fn with_poll_interval(strategy: WaitStrategy, ms: Int) -> WaitStrategy {
  let safe = case ms < 1 {
    True -> 1
    False -> ms
  }
  case strategy {
    WaitStrategy(base, timeout, _) -> WaitStrategy(base, timeout, safe)
  }
}

/// Internal - returns the inner base strategy for pattern matching in
/// `internal/wait_runner.gleam`.
@internal
pub fn base(strategy: WaitStrategy) -> WaitStrategyBase {
  case strategy {
    WaitStrategy(b, _, _) -> b
  }
}

/// Returns the configured timeout in milliseconds.
pub fn timeout_ms(strategy: WaitStrategy) -> Int {
  case strategy {
    WaitStrategy(_, t, _) -> t
  }
}

/// Returns the configured poll interval in milliseconds.
pub fn poll_interval_ms(strategy: WaitStrategy) -> Int {
  case strategy {
    WaitStrategy(_, _, p) -> p
  }
}

/// Human-readable description used in `WaitTimedOut` / `WaitFailed` errors.
pub fn describe(strategy: WaitStrategy) -> String {
  case strategy {
    WaitStrategy(base, timeout, poll) -> {
      let base_desc = case base {
        ForNone -> "none"
        ForLog(message, times) ->
          "log(" <> message <> ", " <> int.to_string(times) <> ")"
        ForPort(port) -> "port(" <> int.to_string(port) <> ")"
        ForHttp(port, path, status) ->
          "http("
          <> int.to_string(port)
          <> ", "
          <> path
          <> ", "
          <> int.to_string(status)
          <> ")"
        ForHealthCheck -> "health_check"
        ForCommand(cmd, expected) ->
          "command("
          <> string.join(cmd, " ")
          <> ", "
          <> int.to_string(expected)
          <> ")"
        AllOf(strats) ->
          "all_of(" <> string.join(list.map(strats, describe), ", ") <> ")"
        AnyOf(strats) ->
          "any_of(" <> string.join(list.map(strats, describe), ", ") <> ")"
      }
      base_desc
      <> " [timeout="
      <> int.to_string(timeout)
      <> ", poll="
      <> int.to_string(poll)
      <> "]"
    }
  }
}
