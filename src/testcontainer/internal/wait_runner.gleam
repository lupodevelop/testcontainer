import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

import testcontainer/error
import testcontainer/exec
import testcontainer/internal/docker
import testcontainer/wait

// ---------------------------------------------------------------------------
// FFI - timing and network helpers from docker_transport.erl
// ---------------------------------------------------------------------------

@external(erlang, "docker_transport", "tcp_can_connect")
fn tcp_can_connect(host: String, port: Int) -> Result(Nil, String)

@external(erlang, "docker_transport", "http_get_status")
fn http_get_status(host: String, port: Int, path: String) -> Result(Int, String)

@external(erlang, "docker_transport", "now_ms")
fn now_ms() -> Int

@external(erlang, "docker_transport", "sleep_ms")
fn sleep_ms(ms: Int) -> Nil

// ---------------------------------------------------------------------------
// Port-binding decoder. Built once and reused for every parse.
// ---------------------------------------------------------------------------

type PortBinding {
  PortBinding(host_port: String)
}

fn port_binding_decoder() -> decode.Decoder(PortBinding) {
  use hp <- decode.field("HostPort", decode.string)
  decode.success(PortBinding(hp))
}

fn ports_decoder() -> decode.Decoder(
  dict.Dict(String, Option(List(PortBinding))),
) {
  decode.at(
    ["NetworkSettings", "Ports"],
    decode.dict(
      decode.string,
      decode.optional(decode.list(port_binding_decoder())),
    ),
  )
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Runs the wait strategy for the given container, polling until it succeeds
/// or the strategy's configured timeout expires. `host` is the host the
/// runner should use to reach mapped ports (already resolved by the caller
/// from `Config.host_override`, so the runner does not re-read the env on
/// every poll).
pub fn run(
  strategy: wait.WaitStrategy,
  container_id: String,
  host: String,
) -> Result(Nil, error.Error) {
  let start = now_ms()
  let deadline = start + wait.timeout_ms(strategy)
  let poll = wait.poll_interval_ms(strategy)
  poll_loop(strategy, container_id, host, dict.new(), start, deadline, poll)
}

// ---------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------

fn poll_loop(
  strategy: wait.WaitStrategy,
  container_id: String,
  host: String,
  port_map: dict.Dict(Int, Int),
  start_ms: Int,
  deadline: Int,
  poll_ms: Int,
) -> Result(Nil, error.Error) {
  let now = now_ms()
  case now >= deadline {
    True -> {
      let elapsed = now - start_ms
      Error(error.WaitTimedOut(wait.describe(strategy), elapsed))
    }
    False -> {
      // One inspect call per poll iteration, shared by health checks and
      // (when needed) port resolution. Once the port map is non-empty,
      // mappings are stable for a running container - keep reusing it
      // across iterations to close the resolve/connect race window.
      let inspect = case docker.inspect_container(container_id) {
        Ok(body) -> Some(body)
        Error(_) -> None
      }
      let pm = case dict.is_empty(port_map), inspect {
        True, Some(body) -> parse_port_map(body)
        _, _ -> port_map
      }
      case check_once(strategy, container_id, host, pm, inspect) {
        Ok(Nil) -> Ok(Nil)
        Error(_) -> {
          sleep_ms(poll_ms)
          poll_loop(
            strategy,
            container_id,
            host,
            pm,
            start_ms,
            deadline,
            poll_ms,
          )
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Single check per strategy variant
// ---------------------------------------------------------------------------

fn check_once(
  strategy: wait.WaitStrategy,
  container_id: String,
  host: String,
  port_map: dict.Dict(Int, Int),
  inspect: Option(String),
) -> Result(Nil, error.Error) {
  case wait.base(strategy) {
    wait.ForNone -> Ok(Nil)
    wait.ForLog(message, times) -> check_log(container_id, message, times)
    wait.ForPort(container_port) -> check_port(container_port, host, port_map)
    wait.ForHttp(container_port, path, expected_status) ->
      check_http(container_port, path, expected_status, host, port_map)
    wait.ForHealthCheck -> check_health(inspect)
    wait.ForCommand(cmd, expected_exit) ->
      check_command(container_id, cmd, expected_exit)
    wait.AllOf(strategies) ->
      check_all_of(strategies, container_id, host, port_map, inspect)
    wait.AnyOf(strategies) ->
      check_any_of(strategies, container_id, host, port_map, inspect)
  }
}

// ---------------------------------------------------------------------------
// Strategy implementations
// ---------------------------------------------------------------------------

fn check_log(
  container_id: String,
  message: String,
  times: Int,
) -> Result(Nil, error.Error) {
  case docker.container_logs(container_id, option.None) {
    Ok(logs) -> {
      let count = count_occurrences(logs, message)
      case count >= times {
        True -> Ok(Nil)
        False ->
          Error(error.WaitFailed(
            "log(" <> message <> ")",
            "found " <> int.to_string(count) <> "/" <> int.to_string(times),
          ))
      }
    }
    Error(e) -> Error(e)
  }
}

fn count_occurrences(haystack: String, needle: String) -> Int {
  case string.split(haystack, needle) {
    [_] -> 0
    parts -> list.length(parts) - 1
  }
}

fn check_port(
  container_port: Int,
  host: String,
  port_map: dict.Dict(Int, Int),
) -> Result(Nil, error.Error) {
  use host_port <- result.try(resolve_host_port(container_port, port_map))
  case tcp_can_connect(host, host_port) {
    Ok(Nil) -> Ok(Nil)
    Error(reason) ->
      Error(error.WaitFailed(
        "port(" <> int.to_string(container_port) <> ")",
        reason,
      ))
  }
}

fn check_http(
  container_port: Int,
  path: String,
  expected_status: Int,
  host: String,
  port_map: dict.Dict(Int, Int),
) -> Result(Nil, error.Error) {
  use host_port <- result.try(resolve_host_port(container_port, port_map))
  case http_get_status(host, host_port, path) {
    Ok(status) ->
      case status == expected_status {
        True -> Ok(Nil)
        False ->
          Error(error.WaitFailed(
            "http(" <> int.to_string(container_port) <> ", " <> path <> ")",
            "got HTTP "
              <> int.to_string(status)
              <> ", want "
              <> int.to_string(expected_status),
          ))
      }
    Error(reason) ->
      Error(error.WaitFailed(
        "http(" <> int.to_string(container_port) <> ", " <> path <> ")",
        reason,
      ))
  }
}

fn check_health(inspect: Option(String)) -> Result(Nil, error.Error) {
  case inspect {
    None ->
      Error(error.WaitFailed("health_check", "unable to inspect container"))
    Some(body) ->
      case
        json.parse(
          body,
          decode.at(["State", "Health", "Status"], decode.string),
        )
      {
        Ok("healthy") -> Ok(Nil)
        Ok(status) ->
          Error(error.WaitFailed("health_check", "status=" <> status))
        Error(_) ->
          Error(error.WaitFailed("health_check", "no health status in inspect"))
      }
  }
}

fn check_command(
  container_id: String,
  cmd: List(String),
  expected_exit: Int,
) -> Result(Nil, error.Error) {
  case docker.exec_container(container_id, cmd) {
    Ok(exec.ExecResult(exit_code, _, _)) ->
      case exit_code == expected_exit {
        True -> Ok(Nil)
        False ->
          Error(error.WaitFailed(
            "command(" <> string.join(cmd, " ") <> ")",
            "exit=" <> int.to_string(exit_code),
          ))
      }
    Error(e) -> Error(e)
  }
}

fn check_all_of(
  strategies: List(wait.WaitStrategy),
  container_id: String,
  host: String,
  port_map: dict.Dict(Int, Int),
  inspect: Option(String),
) -> Result(Nil, error.Error) {
  list.try_map(strategies, fn(s) {
    check_once(s, container_id, host, port_map, inspect)
  })
  |> result.map(fn(_) { Nil })
}

fn check_any_of(
  strategies: List(wait.WaitStrategy),
  container_id: String,
  host: String,
  port_map: dict.Dict(Int, Int),
  inspect: Option(String),
) -> Result(Nil, error.Error) {
  case strategies {
    [] -> Error(error.WaitFailed("any_of", "no strategies provided"))
    [first, ..rest] ->
      case check_once(first, container_id, host, port_map, inspect) {
        Ok(Nil) -> Ok(Nil)
        Error(_) -> check_any_of(rest, container_id, host, port_map, inspect)
      }
  }
}

// ---------------------------------------------------------------------------
// Port-mapping helpers - parsed once per `run`, then reused for every poll.
// ---------------------------------------------------------------------------

fn resolve_host_port(
  container_port: Int,
  port_map: dict.Dict(Int, Int),
) -> Result(Int, error.Error) {
  case dict.get(port_map, container_port) {
    Ok(hp) -> Ok(hp)
    Error(Nil) -> Error(error.PortNotMapped(container_port))
  }
}

fn parse_port_map(inspect_json: String) -> dict.Dict(Int, Int) {
  case json.parse(inspect_json, ports_decoder()) {
    Ok(raw) ->
      raw
      |> dict.to_list
      |> list.filter_map(parse_entry)
      |> dict.from_list
    Error(_) -> dict.new()
  }
}

fn parse_entry(
  entry: #(String, Option(List(PortBinding))),
) -> Result(#(Int, Int), Nil) {
  let #(key, bindings) = entry
  use container_port <- result.try(parse_tcp_key(key))
  use bs <- result.try(case bindings {
    Some(value) -> Ok(value)
    None -> Error(Nil)
  })
  use host_port <- result.try(first_host_port(bs))
  Ok(#(container_port, host_port))
}

fn parse_tcp_key(key: String) -> Result(Int, Nil) {
  case string.split(key, "/") {
    [p, "tcp"] -> int.parse(p)
    _ -> Error(Nil)
  }
}

fn first_host_port(bs: List(PortBinding)) -> Result(Int, Nil) {
  case bs {
    [] -> Error(Nil)
    [PortBinding(hp), ..] -> int.parse(hp)
  }
}
