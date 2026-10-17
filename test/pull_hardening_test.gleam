import gleam/list
import gleam/option.{None}
import gleeunit/should
import testcontainer/error
import testcontainer/internal/docker
import testcontainer/internal/image_ref

@external(erlang, "docker_test_server", "with_responses")
fn with_responses(
  responses: List(#(Int, String, Int)),
  body: fn() -> a,
) -> #(a, List(String))

pub fn pull_error_detail_keeps_message_test() {
  let #(outcome, _) =
    with_responses(
      [#(200, "{\"errorDetail\": {\"message\": \"access denied\"}}\r\n", 0)],
      fn() { docker.pull_image("private:v1", None) },
    )
  outcome
  |> should.equal(Error(error.ImagePullFailed("private:v1", "access denied")))
}

pub fn pull_error_unescapes_json_test() {
  let #(outcome, _) =
    with_responses(
      [
        #(
          200,
          "{\"status\":\"pulling\"}\n{\"error\": \"missing \\\"layer\\\"\\nretry\"}\n",
          0,
        ),
      ],
      fn() { docker.pull_image("private:v1", None) },
    )
  outcome
  |> should.equal(
    Error(error.ImagePullFailed("private:v1", "missing \"layer\"\nretry")),
  )
}

pub fn malformed_pull_stream_cannot_report_success_test() {
  let #(outcome, _) =
    with_responses([#(200, "{\"status\":\"pulling\"}\n{\"error\":", 0)], fn() {
      docker.pull_image("private:v1", None)
    })
  outcome |> should.be_error()
}

pub fn successful_pull_progress_test() {
  let #(outcome, _) =
    with_responses(
      [#(200, "{\"status\":\"Pulling\"}\r\n{\"status\":\"Downloaded\"}\r\n", 0)],
      fn() { docker.pull_image("alpine:3.18", None) },
    )
  outcome |> should.equal(Ok(Nil))
}

pub fn digest_reference_preserves_algorithm_test() {
  image_ref.parse("registry:5000/org/image:v1@sha256:abc123")
  |> should.equal(image_ref.ImageRef("registry:5000/org/image", "sha256:abc123"))
}

pub fn pull_uses_digest_instead_of_tag_test() {
  let #(outcome, requests) =
    with_responses([#(200, "{\"status\":\"Already exists\"}\n", 0)], fn() {
      docker.pull_image("alpine@sha256:abc123", None)
    })
  outcome |> should.equal(Ok(Nil))
  requests
  |> should.equal([
    "POST /images/create?fromImage=alpine&tag=sha256%3Aabc123 HTTP/1.1",
  ])
}

pub fn empty_pull_selectors_are_rejected_before_request_test() {
  list.each(["alpine@", "alpine:", ""], fn(image) {
    let #(outcome, requests) =
      with_responses([#(200, "{\"status\":\"Pulled\"}\n", 0)], fn() {
        docker.pull_image(image, None)
      })
    outcome |> should.equal(Error(error.InvalidImageRef(image)))
    requests |> should.equal([])
  })
}
