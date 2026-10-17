import envie
import gleam/erlang/process
import gleam/int
import gleeunit/should
import testcontainer
import testcontainer/container
import testcontainer/error
import testcontainer/formula
import testcontainer/internal/docker

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "testcontainer_test_support", "with_cleanup")
fn with_cleanup(cleanup: fn() -> Nil, body: fn() -> a) -> a

pub fn standalone_removes_container_after_owner_is_killed_test() {
  case envie.get_bool("TESTCONTAINERS_INTEGRATION", False) {
    False -> Nil
    True -> verify_crash_cleanup()
  }
}

fn verify_crash_cleanup() {
  let name = "tc-standalone-crash-" <> int.to_string(unique_integer())
  let ready: process.Subject(Result(container.Container, error.Error)) =
    process.new_subject()
  let released: process.Subject(Result(Nil, error.Error)) =
    process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let f =
        formula.new_standalone(
          fn() {
            testcontainer.start(
              container.new("alpine:3.18")
              |> container.with_name(name)
              |> container.with_command(["sh", "-c", "sleep 30"]),
            )
          },
          fn() {
            let outcome = docker.remove_container(name)
            process.send(released, outcome)
            outcome
          },
        )
      let outcome =
        testcontainer.with_standalone_formula(f, fn(c) {
          process.send(ready, Ok(c))
          let blocker: process.Subject(Nil) = process.new_subject()
          process.receive_forever(blocker)
          Ok(Nil)
        })
      case outcome {
        Error(e) -> process.send(ready, Error(e))
        Ok(_) -> Nil
      }
    })
  use <- with_cleanup(fn() {
    process.kill(owner)
    let _ = docker.remove_container(name)
    Nil
  })

  let started = process.receive(ready, 60_000)
  process.kill(owner)
  let c = started |> should.be_ok() |> should.be_ok()
  process.receive(released, 10_000) |> should.be_ok() |> should.be_ok()
  // Assert before fallback cleanup, so a leaked container cannot pass.
  let state = docker.inspect_container(container.id(c))
  case state {
    Error(error.DockerApiError(_, _, 404, _)) -> Nil
    _ ->
      state
      |> should.equal(
        Error(error.DockerApiError(
          "GET",
          "/containers/" <> container.id(c) <> "/json",
          404,
          "container should have been removed by release",
        )),
      )
  }
}
