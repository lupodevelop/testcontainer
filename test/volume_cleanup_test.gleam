import envie
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit/should
import testcontainer/internal/docker

@external(erlang, "docker_transport", "request")
fn request(
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "testcontainer_test_support", "with_cleanup")
fn with_cleanup(cleanup: fn() -> Nil, body: fn() -> a) -> a

pub fn removal_deletes_anonymous_volumes_and_preserves_named_volumes_test() {
  case envie.get_bool("TESTCONTAINERS_INTEGRATION", False) {
    False -> Nil
    True -> verify_volume_cleanup()
  }
}

fn verify_volume_cleanup() {
  let name = "tc-volume-cleanup-" <> int.to_string(unique_integer())
  use <- with_cleanup(fn() {
    let _ = docker.remove_container(name)
    let _ = request("DELETE", "/volumes/" <> name, [], "")
    Nil
  })
  case docker.image_exists("alpine:3.18") {
    True -> Nil
    False -> docker.pull_image("alpine:3.18", None) |> should.be_ok()
  }
  let headers = [#("Content-Type", "application/json")]
  request("POST", "/volumes/create", headers, "{\"Name\":\"" <> name <> "\"}")
  |> should.be_ok()
  |> fn(response) { response.0 |> should.equal(201) }

  let body =
    "{\"Image\":\"alpine:3.18\",\"Volumes\":{\"/anonymous\":{}},"
    <> "\"HostConfig\":{\"Mounts\":[{\"Type\":\"volume\",\"Source\":\""
    <> name
    <> "\",\"Target\":\"/named\"}]}}"
  let created =
    request("POST", "/containers/create?name=" <> name, headers, body)
    |> should.be_ok()
  created.0 |> should.equal(201)
  let id =
    json.parse(created.1, decode.at(["Id"], decode.string)) |> should.be_ok()
  let inspect = docker.inspect_container(id) |> should.be_ok()
  let mounts =
    json.parse(inspect, decode.at(["Mounts"], decode.list(mount_decoder())))
    |> should.be_ok()
  let anonymous =
    list.find(mounts, fn(mount) { mount.0 == "/anonymous" })
    |> should.be_ok()

  docker.remove_container(id) |> should.be_ok()
  let anonymous_state =
    request("GET", "/volumes/" <> anonymous.1, [], "")
    |> should.be_ok()
  let named_state =
    request("GET", "/volumes/" <> name, [], "") |> should.be_ok()
  anonymous_state.0 |> should.equal(404)
  named_state.0 |> should.equal(200)
}

fn mount_decoder() -> decode.Decoder(#(String, String)) {
  use destination <- decode.field("Destination", decode.string)
  use name <- decode.field("Name", decode.string)
  decode.success(#(destination, name))
}
