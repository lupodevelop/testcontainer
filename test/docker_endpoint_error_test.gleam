import envie
import gleam/int
import gleam/string
import gleeunit/should
import testcontainer/error
import testcontainer/internal/docker

@external(erlang, "docker_test_server", "with_responses")
fn with_responses(
  responses: List(#(Int, String, Int)),
  body: fn() -> a,
) -> #(a, List(String))

@external(erlang, "testcontainer_test_support", "with_env")
fn with_env(name: String, value: String, body: fn() -> a) -> a

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

pub fn tcp_transport_failure_reports_configured_endpoint_test() {
  let #(#(outcome, endpoint), _) =
    with_responses([#(0, "", 0)], fn() {
      let endpoint =
        envie.get_string("DOCKER_HOST", "")
        |> string.replace("tcp://", "")
      #(docker.ping(), endpoint)
    })
  case outcome {
    Error(error.DockerUnavailable(actual, _)) ->
      actual |> should.equal(endpoint)
    _ ->
      outcome
      |> should.equal(
        Error(error.DockerUnavailable(endpoint, "expected transport failure")),
      )
  }
}

pub fn unix_transport_failure_reports_socket_as_gleam_string_test() {
  let path =
    "/tmp/testcontainer-missing-" <> int.to_string(unique_integer()) <> ".sock"
  let outcome =
    with_env("DOCKER_HOST", "unix://" <> path, fn() { docker.ping() })
  case outcome {
    Error(error.DockerUnavailable(actual, _)) -> actual |> should.equal(path)
    _ ->
      outcome
      |> should.equal(
        Error(error.DockerUnavailable(path, "expected connection failure")),
      )
  }
}
