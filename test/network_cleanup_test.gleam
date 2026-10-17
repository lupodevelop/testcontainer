import envie
import gleam/erlang/process
import gleam/int
import gleam/string
import gleeunit/should
import testcontainer
import testcontainer/container
import testcontainer/error
import testcontainer/internal/docker
import testcontainer/network
import testcontainer/wait

@external(erlang, "docker_transport", "request")
fn request(
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "docker_transport", "now_ms")
fn now_ms() -> Int

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

pub fn network_cleanup_waits_for_crashed_callers_containers_test() {
  case envie.get_bool("TESTCONTAINERS_INTEGRATION", False) {
    False -> Nil
    True -> {
      let name = "tc-network-crash-" <> int.to_string(unique_integer())
      let ready: process.Subject(
        Result(#(network.Network, container.Container), error.Error),
      ) = process.new_subject()

      let owner =
        process.spawn_unlinked(fn() {
          let outcome =
            network.with_network(name, fn(net) {
              testcontainer.with_container(
                container.new("alpine:3.18")
                  |> container.on_network(network.name(net))
                  |> container.wait_for(wait.log("ready-for-crash"))
                  |> container.with_command([
                    "sh",
                    "-c",
                    "trap 'sleep 2; exit 0' TERM; echo ready-for-crash; while :; do sleep 1; done",
                  ]),
                fn(c) {
                  process.send(ready, Ok(#(net, c)))
                  let blocker: process.Subject(Nil) = process.new_subject()
                  process.receive_forever(blocker)
                  Ok(Nil)
                },
              )
            })
          case outcome {
            Error(e) -> process.send(ready, Error(e))
            Ok(_) -> Nil
          }
        })

      let started = process.receive(ready, 60_000)
      process.kill(owner)
      let #(net, c) = started |> should.be_ok() |> should.be_ok()
      let outcome = await_removed(net, c, now_ms() + 10_000)

      // Clean up even when the regression fails, before raising an assertion.
      let _ = testcontainer.force_stop(c)
      let _ = network.remove(net)
      outcome |> should.be_ok()
    }
  }
}

fn await_removed(
  net: network.Network,
  c: container.Container,
  deadline: Int,
) -> Result(Nil, String) {
  let container_state = docker.inspect_container(container.id(c))
  let network_state = request("GET", "/networks/" <> network.id(net), [], "")
  case container_state, network_state {
    Error(error.DockerApiError(_, _, 404, _)), Ok(#(404, _)) -> Ok(Nil)
    _, _ ->
      case now_ms() >= deadline {
        True ->
          Error(
            "resources still present: "
            <> string.inspect(#(container_state, network_state)),
          )
        False -> {
          process.sleep(100)
          await_removed(net, c, deadline)
        }
      }
  }
}
