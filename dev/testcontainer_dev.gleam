import gleam/int
import gleam/result
import gleam/string

import testcontainer
import testcontainer/container
import testcontainer/error
import testcontainer/formula
import testcontainer/network
import testcontainer/port
import testcontainer/wait

import woof

// ---------------------------------------------------------------------------
// Field-builder shorthands for woof 1.6+ FieldValue API
// ---------------------------------------------------------------------------

fn s(key: String, value: String) -> #(String, woof.FieldValue) {
  #(key, woof.FString(value))
}

fn i(key: String, value: Int) -> #(String, woof.FieldValue) {
  #(key, woof.FInt(value))
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main() {
  woof.set_colors(woof.Always)
  woof.info("━━━ testcontainer dev runner ━━━", [])

  run("1 - alpine: start / logs", demo_alpine_logs)
  run("2 - alpine: exec", demo_alpine_exec)
  run("3 - redis:  wait.log + port mapping + mapped_url", demo_redis)
  run("4 - alpine: wait.command", demo_wait_command)
  run("5 - nginx:  wait.port + wait.http", demo_nginx_wait)
  run("6 - alpine: copy_file_to", demo_copy_file_to)
  run("7 - formula: typed output", demo_formula)
  run("8 - network: two containers, same bridge", demo_network)

  woof.info("━━━ all demos done ━━━", [])
}

fn run(label: String, demo: fn() -> Result(Nil, error.Error)) -> Nil {
  woof.info("─── " <> label <> " ───", [])
  case demo() {
    Ok(_) -> woof.info("ok", [])
    Error(e) -> woof.error("FAILED", [s("reason", describe_error(e))])
  }
}

// ---------------------------------------------------------------------------
// Demo 1 - basic lifecycle + logs
// ---------------------------------------------------------------------------

fn demo_alpine_logs() -> Result(Nil, error.Error) {
  testcontainer.with_container(
    container.new("alpine:3.18")
      |> container.with_command([
        "sh",
        "-c",
        "echo '=== container alive ===' && sleep 5",
      ]),
    fn(c) {
      woof.info("container up", [
        s("id", short(container.id(c))),
        s("host", container.host(c)),
      ])
      use logs <- result.try(testcontainer.logs(c))
      woof.info("logs", [s("output", string.trim(logs))])
      Ok(Nil)
    },
  )
}

// ---------------------------------------------------------------------------
// Demo 2 - exec
// ---------------------------------------------------------------------------

fn demo_alpine_exec() -> Result(Nil, error.Error) {
  testcontainer.with_container(
    container.new("alpine:3.18")
      |> container.with_command(["sh", "-c", "sleep 30"]),
    fn(c) {
      use exec_out <- result.try(
        testcontainer.exec(c, ["sh", "-c", "echo host=$(hostname) && uname -r"]),
      )
      woof.info("exec", [
        i("exit", exec_out.exit_code),
        s("stdout", string.trim(exec_out.stdout)),
      ])
      Ok(Nil)
    },
  )
}

// ---------------------------------------------------------------------------
// Demo 3 - redis: wait.log + port mapping + mapped_url
// ---------------------------------------------------------------------------

fn demo_redis() -> Result(Nil, error.Error) {
  let redis_port = port.tcp(6379)
  testcontainer.with_container(
    container.new("redis:7-alpine")
      |> container.expose_port(redis_port)
      |> container.wait_for(
        wait.log("Ready to accept connections")
        |> wait.with_timeout(30_000),
      ),
    fn(c) {
      use hp <- result.try(container.host_port(c, redis_port))
      use url <- result.try(container.mapped_url(c, redis_port, "redis"))
      woof.info("redis ready", [
        s("id", short(container.id(c))),
        i("mapped_port", hp),
        s("url", url),
      ])

      use logs <- result.try(testcontainer.logs(c))
      let ready_line =
        logs
        |> string.split("\n")
        |> find_first(fn(l) { string.contains(l, "Ready to accept") })
      woof.info("readiness log line", [s("line", string.trim(ready_line))])

      Ok(Nil)
    },
  )
}

// ---------------------------------------------------------------------------
// Demo 4 - wait.command
// ---------------------------------------------------------------------------

fn demo_wait_command() -> Result(Nil, error.Error) {
  testcontainer.with_container(
    container.new("alpine:3.18")
      |> container.with_command([
        "sh",
        "-c",
        "sleep 1 && touch /tmp/ready && sleep 30",
      ])
      |> container.wait_for(
        wait.command(["test", "-f", "/tmp/ready"])
        |> wait.with_timeout(15_000)
        |> wait.with_poll_interval(300),
      ),
    fn(c) {
      woof.info("ready file appeared", [s("id", short(container.id(c)))])
      Ok(Nil)
    },
  )
}

// ---------------------------------------------------------------------------
// Demo 5 - nginx: wait.port + wait.http
// ---------------------------------------------------------------------------

fn demo_nginx_wait() -> Result(Nil, error.Error) {
  let http_port = port.tcp(80)
  testcontainer.with_container(
    container.new("nginx:alpine")
      |> container.expose_port(http_port)
      |> container.wait_for(
        wait.all_of([wait.port(80), wait.http(80, "/")])
        |> wait.with_timeout(30_000),
      ),
    fn(c) {
      use hp <- result.try(container.host_port(c, http_port))
      use url <- result.try(container.mapped_url(c, http_port, "http"))
      woof.info("nginx ready", [
        s("id", short(container.id(c))),
        i("host_port", hp),
        s("url", url),
      ])
      Ok(Nil)
    },
  )
}

// ---------------------------------------------------------------------------
// Demo 6 - copy_file_to
// ---------------------------------------------------------------------------

fn demo_copy_file_to() -> Result(Nil, error.Error) {
  let host_path = "/tmp/tc_dev_copy.txt"
  let content = "hello from the host - copy_file_to works!"
  let _ = write_file(host_path, content)

  testcontainer.with_container(
    container.new("alpine:3.18")
      |> container.with_command(["sh", "-c", "sleep 30"]),
    fn(c) {
      use _ <- result.try(testcontainer.copy_file_to(
        c,
        host_path,
        "/tmp/copied.txt",
      ))
      woof.info("file copied to container", [
        s("host", host_path),
        s("container", "/tmp/copied.txt"),
      ])

      use exec_out <- result.try(
        testcontainer.exec(c, ["cat", "/tmp/copied.txt"]),
      )
      woof.info("file contents verified", [
        s("content", string.trim(exec_out.stdout)),
      ])

      Ok(Nil)
    },
  )
}

// ---------------------------------------------------------------------------
// Demo 7 - Formula(output): typed extraction
// ---------------------------------------------------------------------------

// A minimal inline formula that starts nginx and returns a typed record.
type NginxInfo {
  NginxInfo(id: String, host: String, http_port: Int, base_url: String)
}

fn nginx_formula() -> formula.Formula(NginxInfo) {
  let p = port.tcp(80)
  formula.new(
    container.new("nginx:alpine")
      |> container.expose_port(p)
      |> container.wait_for(
        wait.all_of([wait.port(80), wait.http(80, "/")])
        |> wait.with_timeout(30_000),
      ),
    fn(c) {
      use hp <- result.try(container.host_port(c, p))
      use url <- result.try(container.mapped_url(c, p, "http"))
      Ok(NginxInfo(
        id: short(container.id(c)),
        host: container.host(c),
        http_port: hp,
        base_url: url,
      ))
    },
  )
}

fn demo_formula() -> Result(Nil, error.Error) {
  testcontainer.with_formula(nginx_formula(), fn(info) {
    woof.info("nginx formula output", [
      s("id", info.id),
      s("host", info.host),
      i("port", info.http_port),
      s("base_url", info.base_url),
    ])
    Ok(Nil)
  })
}

// ---------------------------------------------------------------------------
// Demo 8 - Network: two containers on the same bridge, ping each other
// ---------------------------------------------------------------------------

fn demo_network() -> Result(Nil, error.Error) {
  use net <- result.try(
    network.with_network("tc-dev-net", fn(net) {
      woof.info("network created", [
        s("id", short(network.id(net))),
        s("name", network.name(net)),
      ])

      // Start a named "server" container on the network.
      use _ <- result.try(
        testcontainer.with_container(
          container.new("alpine:3.18")
            |> container.with_name("tc-dev-server")
            |> container.on_network(network.name(net))
            |> container.with_command(["sh", "-c", "sleep 30"]),
          fn(server) {
            woof.info("server container up", [
              s("id", short(container.id(server))),
              s("name", "tc-dev-server"),
            ])

            // Start a "client" container on the same network and ping the server.
            testcontainer.with_container(
              container.new("alpine:3.18")
                |> container.on_network(network.name(net))
                |> container.with_command(["sh", "-c", "sleep 30"]),
              fn(client) {
                woof.info("client container up", [
                  s("id", short(container.id(client))),
                ])

                use ping_out <- result.try(
                  testcontainer.exec(client, [
                    "ping", "-c", "2", "tc-dev-server",
                  ]),
                )
                woof.info("ping result", [
                  i("exit", ping_out.exit_code),
                  s(
                    "summary",
                    ping_out.stdout
                      |> string.split("\n")
                      |> find_last
                      |> string.trim,
                  ),
                ])
                Ok(Nil)
              },
            )
          },
        ),
      )

      Ok(net)
    }),
  )

  woof.info("network removed", [s("name", network.name(net))])
  Ok(Nil)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn short(id: String) -> String {
  string.slice(id, 0, 12)
}

fn find_first(lst: List(String), pred: fn(String) -> Bool) -> String {
  case lst {
    [] -> ""
    [h, ..rest] ->
      case pred(h) {
        True -> h
        False -> find_first(rest, pred)
      }
  }
}

fn find_last(lst: List(String)) -> String {
  case lst {
    [] -> ""
    [x] -> x
    [_, ..rest] -> find_last(rest)
  }
}

@external(erlang, "file", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)

fn describe_error(e: error.Error) -> String {
  case e {
    error.DockerUnavailable(path, reason) ->
      "docker unavailable [" <> path <> "]: " <> reason
    error.ImagePullFailed(image, reason) ->
      "pull failed [" <> image <> "]: " <> reason
    error.ContainerCreateFailed(image, reason) ->
      "create failed [" <> image <> "]: " <> reason
    error.ContainerStartFailed(id, reason) ->
      "start failed [" <> short(id) <> "]: " <> reason
    error.ContainerStopFailed(id, reason) ->
      "stop failed [" <> short(id) <> "]: " <> reason
    error.WaitTimedOut(strategy, ms) ->
      "wait timed out [" <> strategy <> "] after " <> int.to_string(ms) <> "ms"
    error.WaitFailed(strategy, reason) ->
      "wait failed [" <> strategy <> "]: " <> reason
    error.ExecFailed(id, cmd, exit_code, stderr) ->
      "exec failed ["
      <> short(id)
      <> "] cmd="
      <> string.join(cmd, " ")
      <> " exit="
      <> int.to_string(exit_code)
      <> " stderr="
      <> stderr
    error.PortNotMapped(p) -> "port " <> int.to_string(p) <> " not mapped"
    error.FileCopyFailed(path, reason) ->
      "file copy failed [" <> path <> "]: " <> reason
    error.PortMappingParseFailed(id, reason) ->
      "port mapping parse failed [" <> short(id) <> "]: " <> reason
    error.DockerApiError(method, path, status, body) ->
      "docker api "
      <> method
      <> " "
      <> path
      <> " → "
      <> int.to_string(status)
      <> ": "
      <> body
    error.InvalidImageRef(raw) -> "invalid image ref: " <> raw
    error.InvalidPort(n) -> "invalid port: " <> int.to_string(n)
  }
}
