import envie
import gleam/erlang/process
import gleam/int
import gleam/result
import gleam/string
import gleeunit/should
import testcontainer
import testcontainer/container
import testcontainer/error
import testcontainer/formula
import testcontainer/network
import testcontainer/port
import testcontainer/wait

fn integration_enabled() -> Bool {
  envie.get_bool("TESTCONTAINERS_INTEGRATION", False)
}

// ---------------------------------------------------------------------------
// Basic lifecycle
// ---------------------------------------------------------------------------

pub fn docker_integration_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "sleep 10"]),
        fn(c) {
          { container.id(c) == "" } |> should.be_false()
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Logs
// ---------------------------------------------------------------------------

pub fn container_logs_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "echo hello-from-logs"]),
        fn(c) {
          let logs = testcontainer.logs(c) |> should.be_ok()
          logs |> should.not_equal("")
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Exec
// ---------------------------------------------------------------------------

pub fn container_exec_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "sleep 30"]),
        fn(c) {
          let result =
            testcontainer.exec(c, ["echo", "hello"]) |> should.be_ok()
          result.exit_code |> should.equal(0)
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

pub fn exec_nonzero_exit_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "sleep 30"]),
        fn(c) {
          let result =
            testcontainer.exec(c, ["sh", "-c", "exit 42"]) |> should.be_ok()
          result.exit_code |> should.equal(42)
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Wait strategies
// ---------------------------------------------------------------------------

pub fn wait_for_log_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command([
            "sh",
            "-c",
            "echo container-ready && sleep 30",
          ])
          |> container.wait_for(wait.log("container-ready")),
        fn(c) {
          { container.id(c) == "" } |> should.be_false()
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

pub fn wait_for_port_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("nginx:alpine")
          |> container.expose_port(port.tcp(80))
          |> container.wait_for(wait.port(80)),
        fn(c) {
          let hp = container.host_port(c, port.tcp(80)) |> should.be_ok()
          { hp > 0 } |> should.be_true()
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

pub fn wait_for_command_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      // Container writes /tmp/ready after 1 s; wait.command polls until it exists.
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command([
            "sh",
            "-c",
            "sleep 1 && touch /tmp/ready && sleep 30",
          ])
          |> container.wait_for(
            wait.command(["test", "-f", "/tmp/ready"])
            |> wait.with_timeout(10_000)
            |> wait.with_poll_interval(300),
          ),
        fn(c) {
          { container.id(c) == "" } |> should.be_false()
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

pub fn wait_timeout_returns_error_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      // File never appears - wait must time out and return an error.
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "sleep 30"])
          |> container.wait_for(
            wait.command(["test", "-f", "/tmp/never"])
            |> wait.with_timeout(1000)
            |> wait.with_poll_interval(200),
          ),
        fn(_c) { Ok(Nil) },
      )
      |> should.be_error()
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// Network lifecycle
// ---------------------------------------------------------------------------

pub fn network_create_remove_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let network_name = unique_name("testcontainer-test-net")
      network.with_network(network_name, fn(net) {
        { network.id(net) == "" } |> should.be_false()
        { network.name(net) == network_name } |> should.be_true()
        Ok(Nil)
      })
      |> should.be_ok()
    }
  }
}

pub fn container_on_network_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let network_name = unique_name("testcontainer-containers-net")
      network.with_network(network_name, fn(net) {
        testcontainer.with_container(
          container.new("alpine:3.18")
            |> container.with_command(["sh", "-c", "sleep 10"])
            |> container.on_network(network.name(net)),
          fn(c) {
            { container.id(c) == "" } |> should.be_false()
            Ok(Nil)
          },
        )
      })
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Guard crash cleanup
//
// Spawns a process that starts a container then exits abnormally.
// After a short delay we verify the container is no longer running by
// checking that a second start/stop cycle does not conflict (Docker would
// error on duplicate named containers if the first were still alive).
// ---------------------------------------------------------------------------

pub fn guard_crash_cleanup_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      // `process.spawn/1` is linked; trap exits in this test process so the
      // child panic used for simulation does not fail the test itself.
      process.trap_exits(True)
      let container_name = unique_name("guard-crash-test")
      // Subject used to signal this test process once the container is up.
      let ready: process.Subject(Nil) = process.new_subject()

      // Spawn a process that starts a named container then panics,
      // simulating a test process crash before cleanup runs.
      process.spawn(fn() {
        let _ =
          testcontainer.with_container(
            container.new("alpine:3.18")
              |> container.with_name(container_name)
              |> container.with_command(["sh", "-c", "sleep 30"]),
            fn(_c) {
              process.send(ready, Nil)
              panic as "simulated crash - guard must clean up"
            },
          )
        Nil
      })

      // Wait up to 60 s for the container to be running.
      let _ = process.receive(ready, 60_000)

      // Cleanup is fire-and-forget, so poll until name reuse succeeds.
      assert_name_reusable(container_name, 30_000)
      |> should.be_ok()
      process.trap_exits(False)
    }
  }
}

// ---------------------------------------------------------------------------
// copy_file_to
// ---------------------------------------------------------------------------

pub fn copy_file_to_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let host_path = "/tmp/tc_copy_test_gleam.txt"
      let content = "hello from copy_file_to"
      let _ = write_host_file(host_path, content)

      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "sleep 30"]),
        fn(c) {
          use _ <- result.try(testcontainer.copy_file_to(
            c,
            host_path,
            "/tmp/copied.txt",
          ))
          use exec_result <- result.try(
            testcontainer.exec(c, ["cat", "/tmp/copied.txt"]),
          )
          exec_result.stdout |> string.trim() |> should.equal(content)
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// with_formula
// ---------------------------------------------------------------------------

pub fn with_formula_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let alpine_formula =
        formula.new(
          container.new("alpine:3.18")
            |> container.with_command([
              "sh",
              "-c",
              "echo formula-ready && sleep 30",
            ])
            |> container.wait_for(wait.log("formula-ready")),
          fn(c) { Ok(#(container.id(c), container.host(c))) },
        )

      testcontainer.with_formula(alpine_formula, fn(output) {
        let #(id, host) = output
        { id == "" } |> should.be_false()
        { host == "" } |> should.be_false()
        Ok(Nil)
      })
      |> should.be_ok()
    }
  }
}

pub fn with_formula_extract_error_propagates_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let bad_formula =
        formula.new(
          container.new("alpine:3.18")
            |> container.with_command(["sh", "-c", "sleep 5"]),
          fn(_c) { Error(error.InvalidImageRef("forced error")) },
        )

      testcontainer.with_formula(bad_formula, fn(_) { Ok(Nil) })
      |> should.be_error()
      Nil
    }
  }
}

// ---------------------------------------------------------------------------
// with_container_mapped - body returns custom error type
// ---------------------------------------------------------------------------

type AppError {
  ContainerErr(error.Error)
  AppLogic(String)
}

pub fn with_container_mapped_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let outcome =
        testcontainer.with_container_mapped(
          container.new("alpine:3.18")
            |> container.with_command(["sh", "-c", "sleep 5"]),
          ContainerErr,
          fn(c) {
            { container.id(c) == "" } |> should.be_false()
            Ok(42)
          },
        )
      case outcome {
        Ok(v) -> v |> should.equal(42)
        Error(_) -> should.equal("unexpected error", "")
      }
    }
  }
}

pub fn with_container_mapped_propagates_app_error_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let outcome =
        testcontainer.with_container_mapped(
          container.new("alpine:3.18")
            |> container.with_command(["sh", "-c", "sleep 5"]),
          ContainerErr,
          fn(_c) { Error(AppLogic("boom")) },
        )
      case outcome {
        Error(AppLogic(msg)) -> msg |> should.equal("boom")
        _ -> should.equal("expected AppLogic error", "")
      }
    }
  }
}

// ---------------------------------------------------------------------------
// start_and_keep forces keep regardless of TESTCONTAINERS_KEEP
// ---------------------------------------------------------------------------

pub fn start_and_keep_forces_keep_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let name = unique_name("start-and-keep")
      let c =
        testcontainer.start_and_keep(
          container.new("alpine:3.18")
          |> container.with_name(name)
          |> container.with_command(["sh", "-c", "sleep 60"]),
        )
        |> should.be_ok()

      container.keep(c) |> should.be_true()
      testcontainer.stop(c) |> should.be_ok()
      testcontainer.exec(c, ["echo", "still-running"]) |> should.be_ok()
      testcontainer.force_stop(c) |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// AllOf / AnyOf - composed wait strategies must terminate
// ---------------------------------------------------------------------------

pub fn wait_all_of_terminates_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("nginx:alpine")
          |> container.expose_port(port.tcp(80))
          |> container.wait_for(
            wait.all_of([wait.port(80), wait.http(80, "/")])
            |> wait.with_timeout(30_000),
          ),
        fn(c) {
          container.host_port(c, port.tcp(80)) |> should.be_ok()
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

pub fn wait_any_of_terminates_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command([
            "sh",
            "-c",
            "echo any-of-ready && sleep 30",
          ])
          |> container.wait_for(
            wait.any_of([
              wait.log("any-of-ready"),
              // This second branch will never succeed, ensuring the first path
              // really is what completes the wait.
              wait.command(["test", "-f", "/never"]),
            ])
            |> wait.with_timeout(15_000),
          ),
        fn(_c) { Ok(Nil) },
      )
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Exec stderr split - non-zero command must populate stderr
// ---------------------------------------------------------------------------

pub fn exec_stderr_split_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      testcontainer.with_container(
        container.new("alpine:3.18")
          |> container.with_command(["sh", "-c", "sleep 30"]),
        fn(c) {
          let r =
            testcontainer.exec(c, [
              "sh",
              "-c",
              "echo on-stdout && echo on-stderr 1>&2 && exit 3",
            ])
            |> should.be_ok()
          r.exit_code |> should.equal(3)
          string.contains(r.stdout, "on-stdout") |> should.be_true()
          string.contains(r.stderr, "on-stderr") |> should.be_true()
          Ok(Nil)
        },
      )
      |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Stack - two containers on a shared network, cleanup ordering
// ---------------------------------------------------------------------------

pub fn with_stack_pings_across_containers_test() {
  case integration_enabled() {
    False -> Nil
    True -> {
      let stack_network = unique_name("tc-stack-test-net")
      let stack_server = unique_name("tc-stack-server")
      let outcome =
        testcontainer.with_stack(
          testcontainer.stack(stack_network, fn(net) { Ok(net) }),
          fn(net) {
            testcontainer.with_container(
              container.new("alpine:3.18")
                |> container.with_name(stack_server)
                |> container.on_network(network.name(net))
                |> container.with_command(["sh", "-c", "sleep 30"]),
              fn(_server) {
                testcontainer.with_container(
                  container.new("alpine:3.18")
                    |> container.on_network(network.name(net))
                    |> container.with_command(["sh", "-c", "sleep 30"]),
                  fn(client) {
                    let r =
                      testcontainer.exec(client, [
                        "ping", "-c", "1", stack_server,
                      ])
                      |> should.be_ok()
                    r.exit_code |> should.equal(0)
                    Ok(Nil)
                  },
                )
              },
            )
          },
        )
      outcome |> should.be_ok()
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

@external(erlang, "file", "write_file")
fn write_host_file(path: String, content: String) -> Result(Nil, String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

fn unique_name(prefix: String) -> String {
  prefix <> "-" <> int.to_string(unique_integer())
}

fn assert_name_reusable(
  name: String,
  remaining_ms: Int,
) -> Result(Nil, error.Error) {
  let reuse_attempt =
    testcontainer.with_container(
      container.new("alpine:3.18")
        |> container.with_name(name)
        |> container.with_command(["sh", "-c", "sleep 1"]),
      fn(_c) { Ok(Nil) },
    )

  case reuse_attempt {
    Ok(Nil) -> Ok(Nil)
    Error(error.ContainerCreateFailed(image, reason)) ->
      case remaining_ms > 0 && string.contains(reason, "already in use") {
        True -> {
          process.sleep(500)
          assert_name_reusable(name, remaining_ms - 500)
        }
        False -> Error(error.ContainerCreateFailed(image, reason))
      }
    Error(e) -> Error(e)
  }
}
