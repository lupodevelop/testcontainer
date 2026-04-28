import cowl
import gleam/string
import gleeunit/should
import testcontainer/port
import testcontainer/wait

pub fn port_number_test() {
  let p = port.tcp(5432)
  port.number(p) |> should.equal(5432)
  port.protocol(p) |> should.equal("tcp")
}

pub fn port_udp_test() {
  let p = port.udp(53)
  port.number(p) |> should.equal(53)
  port.protocol(p) |> should.equal("udp")
}

pub fn wait_describe_log_test() {
  let s = wait.log("ready")
  let d = wait.describe(s)
  string.contains(d, "log(ready") |> should.be_true()
}

pub fn wait_describe_http_test() {
  let s = wait.http(8080, "/health")
  let d = wait.describe(s)
  string.contains(d, "http(8080") |> should.be_true()
}

pub fn wait_describe_port_test() {
  let s = wait.port(6379)
  let d = wait.describe(s)
  string.contains(d, "port(6379") |> should.be_true()
}

pub fn wait_timeout_test() {
  let s = wait.log("ready") |> wait.with_timeout(5000)
  wait.timeout_ms(s) |> should.equal(5000)
}

pub fn wait_poll_interval_test() {
  let s = wait.log("ready") |> wait.with_poll_interval(500)
  wait.poll_interval_ms(s) |> should.equal(500)
}

pub fn wait_all_of_describe_test() {
  let s = wait.all_of([wait.log("ready"), wait.port(5432)])
  let d = wait.describe(s)
  string.contains(d, "all_of") |> should.be_true()
}

pub fn wait_any_of_describe_test() {
  let s = wait.any_of([wait.log("ready"), wait.http(8080, "/health")])
  let d = wait.describe(s)
  string.contains(d, "any_of") |> should.be_true()
}

// ---------------------------------------------------------------------------
// ExecResult helpers
// ---------------------------------------------------------------------------

import testcontainer/exec

pub fn exec_result_succeeded_test() {
  let r = exec.ExecResult(0, "ok\n", "")
  exec.succeeded(r) |> should.be_true()
}

pub fn exec_result_failed_test() {
  let r = exec.ExecResult(1, "", "error\n")
  exec.succeeded(r) |> should.be_false()
}

pub fn exec_result_output_test() {
  let r = exec.ExecResult(0, "out", "err")
  exec.output(r) |> should.equal("outerr")
}

// ---------------------------------------------------------------------------
// ImageRef parsing
// ---------------------------------------------------------------------------

import testcontainer/internal/image_ref

pub fn image_ref_simple_test() {
  let ref = image_ref.parse("alpine:3.18")
  ref.name |> should.equal("alpine")
  ref.tag |> should.equal("3.18")
}

pub fn image_ref_no_tag_test() {
  let ref = image_ref.parse("alpine")
  ref.name |> should.equal("alpine")
  ref.tag |> should.equal("latest")
}

pub fn image_ref_registry_with_port_test() {
  // registry:5000/org/image:tag - the "5000" should NOT be taken as tag
  let ref = image_ref.parse("registry.io:5000/postgres:16")
  ref.name |> should.equal("registry.io:5000/postgres")
  ref.tag |> should.equal("16")
}

pub fn image_ref_no_tag_with_registry_test() {
  let ref = image_ref.parse("registry.io:5000/postgres")
  ref.tag |> should.equal("latest")
}

// ---------------------------------------------------------------------------
// Docker transport
// ---------------------------------------------------------------------------

import testcontainer/internal/docker

pub fn docker_transport_chunked_response_test() {
  let raw =
    "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
    <> "58\r\n{"
    <> "\"Id\":\"abc\"}"
    <> "\r\n0\r\n\r\n"

  case docker.parse_response(raw) {
    Ok(#(201, body)) ->
      string.contains(body, "\"Id\":\"abc\"") |> should.be_true()
    Ok(#(_, _)) -> should.equal("unexpected status", "")
    Error(e) -> should.equal(e, "")
  }
}

pub fn docker_transport_plain_response_test() {
  let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nOK"
  case docker.parse_response(raw) {
    Ok(#(200, body)) -> body |> should.equal("OK")
    Ok(#(_, _)) -> should.equal("unexpected status", "")
    Error(e) -> should.equal(e, "")
  }
}

// ---------------------------------------------------------------------------
// Container.with_keep - used by start_and_keep to force the keep flag
// ---------------------------------------------------------------------------

import gleam/dict
import testcontainer/container

pub fn container_with_keep_flips_flag_test() {
  let c = container.build("id-123", "127.0.0.1", dict.new(), False, 10)
  container.keep(c) |> should.be_false()

  let kept = container.with_keep(c, True)
  container.keep(kept) |> should.be_true()
  container.id(kept) |> should.equal("id-123")
}

pub fn container_host_default_test() {
  let c = container.build("id", "127.0.0.1", dict.new(), False, 10)
  container.host(c) |> should.equal("127.0.0.1")
}

// ---------------------------------------------------------------------------
// Wait composition describe
// ---------------------------------------------------------------------------

pub fn wait_all_of_describe_includes_children_test() {
  let s = wait.all_of([wait.log("ready"), wait.port(5432)])
  let d = wait.describe(s)
  string.contains(d, "log(ready") |> should.be_true()
  string.contains(d, "port(5432") |> should.be_true()
}

pub fn wait_any_of_describe_includes_children_test() {
  let s = wait.any_of([wait.log("a"), wait.http(80, "/healthz")])
  let d = wait.describe(s)
  string.contains(d, "log(a") |> should.be_true()
  string.contains(d, "http(80") |> should.be_true()
}

pub fn wait_none_describe_test() {
  wait.none() |> wait.describe |> string.contains("none") |> should.be_true()
}

// ---------------------------------------------------------------------------
// Port validated constructors
// ---------------------------------------------------------------------------

pub fn port_try_tcp_valid_test() {
  port.try_tcp(5432) |> should.be_ok()
}

pub fn port_try_tcp_zero_rejected_test() {
  port.try_tcp(0) |> should.be_error()
}

pub fn port_try_tcp_above_range_rejected_test() {
  port.try_tcp(70_000) |> should.be_error()
}

pub fn port_try_udp_valid_test() {
  port.try_udp(53) |> should.be_ok()
}

pub fn port_try_udp_negative_rejected_test() {
  port.try_udp(-1) |> should.be_error()
}

// ---------------------------------------------------------------------------
// Secret redaction - env values must never leak via string.inspect
// ---------------------------------------------------------------------------

pub fn with_env_does_not_leak_value_in_inspect_test() {
  let spec =
    container.new("alpine:3.18")
    |> container.with_env("DB_PASSWORD", "supersecret-do-not-leak")
  let inspected = string.inspect(spec)
  string.contains(inspected, "supersecret-do-not-leak")
  |> should.be_false()
}

pub fn with_secret_env_does_not_leak_value_in_inspect_test() {
  let spec =
    container.new("alpine:3.18")
    |> container.with_secret_env(
      "API_TOKEN",
      cowl.secret("token-must-stay-redacted"),
    )
  let inspected = string.inspect(spec)
  string.contains(inspected, "token-must-stay-redacted")
  |> should.be_false()
}

pub fn with_envs_does_not_leak_values_in_inspect_test() {
  let spec =
    container.new("alpine:3.18")
    |> container.with_envs([
      #("USER", "app"),
      #("PASSWORD", "another-leak-canary"),
    ])
  let inspected = string.inspect(spec)
  string.contains(inspected, "another-leak-canary")
  |> should.be_false()
}

// ---------------------------------------------------------------------------
// Wait input clamping
// ---------------------------------------------------------------------------

pub fn wait_with_timeout_clamps_negative_test() {
  let s = wait.log("ready") |> wait.with_timeout(-1)
  wait.timeout_ms(s) |> should.equal(0)
}

pub fn wait_with_timeout_accepts_zero_test() {
  let s = wait.log("ready") |> wait.with_timeout(0)
  wait.timeout_ms(s) |> should.equal(0)
}

pub fn wait_with_poll_interval_clamps_zero_test() {
  let s = wait.log("ready") |> wait.with_poll_interval(0)
  wait.poll_interval_ms(s) |> should.equal(1)
}

pub fn wait_with_poll_interval_clamps_negative_test() {
  let s = wait.log("ready") |> wait.with_poll_interval(-5)
  wait.poll_interval_ms(s) |> should.equal(1)
}

// ---------------------------------------------------------------------------
// Pull policy parsing (case-insensitive)
// ---------------------------------------------------------------------------

import testcontainer/internal/config

pub fn pull_policy_lowercase_test() {
  config.parse_pull_policy("always") |> should.equal(config.Always)
  config.parse_pull_policy("never") |> should.equal(config.Never)
  config.parse_pull_policy("missing") |> should.equal(config.IfMissing)
}

pub fn pull_policy_uppercase_test() {
  config.parse_pull_policy("ALWAYS") |> should.equal(config.Always)
  config.parse_pull_policy("NEVER") |> should.equal(config.Never)
}

pub fn pull_policy_mixed_case_test() {
  config.parse_pull_policy("Always") |> should.equal(config.Always)
  config.parse_pull_policy("Never") |> should.equal(config.Never)
}

pub fn pull_policy_unknown_falls_back_test() {
  config.parse_pull_policy("nonsense") |> should.equal(config.IfMissing)
  config.parse_pull_policy("") |> should.equal(config.IfMissing)
}

// ---------------------------------------------------------------------------
// ImageRef edge cases (heuristic documented in image_ref.gleam)
// ---------------------------------------------------------------------------

pub fn image_ref_bare_host_port_takes_port_as_tag_test() {
  // Documented edge case: with no `/` segment, the trailing colon-segment
  // is treated as a tag. To force the registry-port interpretation,
  // append the image name (see test below).
  let ref = image_ref.parse("registry:5000")
  ref.name |> should.equal("registry")
  ref.tag |> should.equal("5000")
}

pub fn image_ref_localhost_with_port_test() {
  let ref = image_ref.parse("localhost:8000/myimg")
  ref.name |> should.equal("localhost:8000/myimg")
  ref.tag |> should.equal("latest")
}

pub fn image_ref_localhost_with_port_and_tag_test() {
  let ref = image_ref.parse("localhost:8000/myimg:1.2.3")
  ref.name |> should.equal("localhost:8000/myimg")
  ref.tag |> should.equal("1.2.3")
}

// ---------------------------------------------------------------------------
// Container.stop_timeout_sec accessor
// ---------------------------------------------------------------------------

pub fn container_carries_stop_timeout_test() {
  let c = container.build("id", "127.0.0.1", dict.new(), False, 15)
  container.stop_timeout_sec(c) |> should.equal(15)
}

pub fn container_with_keep_preserves_stop_timeout_test() {
  let c =
    container.build("id", "127.0.0.1", dict.new(), False, 7)
    |> container.with_keep(True)
  container.stop_timeout_sec(c) |> should.equal(7)
}

// ---------------------------------------------------------------------------
// Public API surface: force_stop must exist and have the expected signature
// (compile-time check; runtime behaviour is covered by integration tests).
// ---------------------------------------------------------------------------

import testcontainer
import testcontainer/error as tc_error

pub fn force_stop_is_public_test() {
  let _ref: fn(container.Container) -> Result(Nil, tc_error.Error) =
    testcontainer.force_stop
  Nil
}
