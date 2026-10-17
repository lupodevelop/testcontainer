import gleam/dict
import gleam/erlang/process
import gleeunit/should
import testcontainer
import testcontainer/container
import testcontainer/error
import testcontainer/internal/docker
import testcontainer/network

@external(erlang, "docker_test_server", "with_responses")
fn with_responses(
  responses: List(#(Int, String, Int)),
  body: fn() -> a,
) -> #(a, List(String))

@external(erlang, "docker_test_server", "with_observed_responses")
fn with_observed_responses(
  responses: List(#(Int, String, Int)),
  on_request: fn(String) -> Nil,
  body: fn() -> a,
) -> #(a, List(String))

pub fn network_guard_survives_caller_death_during_cleanup_test() {
  let seen = process.new_subject()
  let #(retry, _) =
    with_observed_responses(
      [
        #(201, "{\"Id\":\"owned-net\"}", 0),
        #(500, "interrupted", 100),
        #(204, "", 0),
      ],
      fn(line) { process.send(seen, line) },
      fn() {
        let owner =
          process.spawn_unlinked(fn() {
            network.with_network("owned-net", fn(_) { Ok(Nil) })
          })
        let create = process.receive(seen, 1000)
        let first_delete = process.receive(seen, 1000)
        process.kill(owner)
        create |> should.equal(Ok("POST /networks/create HTTP/1.1"))
        first_delete |> should.equal(Ok("DELETE /networks/owned-net HTTP/1.1"))
        process.receive(seen, 1000)
      },
    )
  retry |> should.equal(Ok("DELETE /networks/owned-net HTTP/1.1"))
}

fn handle() -> container.Container {
  container.build("owned", "127.0.0.1", dict.new(), False, 1)
}

pub fn force_stop_removes_even_after_stop_failure_test() {
  let #(outcome, requests) =
    with_responses([#(500, "stop failed", 0), #(204, "", 0)], fn() {
      testcontainer.force_stop(handle())
    })
  // The resource is gone, so successful forced removal completes cleanup.
  outcome |> should.equal(Ok(Nil))
  requests
  |> should.equal([
    "POST /containers/owned/stop?t=1 HTTP/1.1",
    "DELETE /containers/owned?force=true&v=true HTTP/1.1",
  ])
}

pub fn force_stop_reports_removal_failure_test() {
  let #(outcome, _) =
    with_responses([#(500, "stop failed", 0), #(403, "denied", 0)], fn() {
      testcontainer.force_stop(handle())
    })
  outcome
  |> should.equal(
    Error(error.DockerApiError(
      "DELETE",
      "/containers/owned?force=true&v=true",
      403,
      "denied",
    )),
  )
}

pub fn force_stop_is_idempotent_for_missing_container_test() {
  let #(outcome, requests) =
    with_responses([#(404, "missing", 0), #(404, "missing", 0)], fn() {
      testcontainer.force_stop(handle())
    })
  outcome |> should.equal(Ok(Nil))
  requests
  |> should.equal([
    "POST /containers/owned/stop?t=1 HTTP/1.1",
    "DELETE /containers/owned?force=true&v=true HTTP/1.1",
  ])
}

pub fn remove_requests_anonymous_volume_cleanup_test() {
  let #(outcome, requests) =
    with_responses([#(204, "", 0)], fn() { docker.remove_container("owned") })
  outcome |> should.equal(Ok(Nil))
  requests
  |> should.equal(["DELETE /containers/owned?force=true&v=true HTTP/1.1"])
}
