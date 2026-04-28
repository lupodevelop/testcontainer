import cowl
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

import gleam/bit_array
import testcontainer/container
import testcontainer/error
import testcontainer/exec
import testcontainer/internal/config
import testcontainer/internal/image_ref
import testcontainer/port

// This module is a thin wrapper around the Docker Engine API using the local
// Docker Unix socket. It uses a small Erlang helper to talk to the socket via
// raw gen_tcp.

@external(erlang, "docker_transport", "request")
fn transport_request(
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), String)

@external(erlang, "docker_transport", "socket_path")
fn transport_socket_path() -> String

@external(erlang, "docker_transport", "parse_response")
fn transport_parse_response(data: String) -> Result(#(Int, String), String)

@external(erlang, "docker_transport", "strip_log_frames")
fn strip_log_frames(data: String) -> String

@external(erlang, "docker_transport", "split_log_streams")
fn split_log_streams(data: String) -> #(String, String)

@external(erlang, "docker_transport", "copy_file_to_container")
fn transport_copy_file(
  container_id: String,
  host_path: String,
  container_path: String,
) -> Result(Nil, String)

@internal
pub fn parse_response(data: String) -> Result(#(Int, String), String) {
  transport_parse_response(data)
}

fn url_encode(input: String) -> String {
  // Single pass over graphemes; replace reserved characters in one walk
  // instead of running `string.replace` 11 times over the whole string.
  input
  |> string.to_graphemes
  |> list.map(encode_grapheme)
  |> string.concat
}

fn encode_grapheme(g: String) -> String {
  case g {
    "%" -> "%25"
    "\r" -> "%0D"
    "\n" -> "%0A"
    " " -> "%20"
    "/" -> "%2F"
    ":" -> "%3A"
    "=" -> "%3D"
    "?" -> "%3F"
    "&" -> "%26"
    "#" -> "%23"
    "+" -> "%2B"
    other -> other
  }
}

fn contains_crlf(input: String) -> Bool {
  string.contains(input, "\r") || string.contains(input, "\n")
}

fn request(
  method: String,
  path: String,
  body: String,
) -> Result(#(Int, String), error.Error) {
  request_with_headers(
    method,
    path,
    [#("Content-Type", "application/json")],
    body,
  )
}

fn request_with_headers(
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(#(Int, String), error.Error) {
  case transport_request(method, path, headers, body) {
    Ok(#(status, response)) -> Ok(#(status, response))
    Error(reason) ->
      Error(error.DockerUnavailable(transport_socket_path(), reason))
  }
}

fn check_ok(
  method: String,
  path: String,
  status: Int,
  body: String,
) -> Result(Nil, error.Error) {
  case status {
    200 -> Ok(Nil)
    201 -> Ok(Nil)
    204 -> Ok(Nil)
    _ -> Error(error.DockerApiError(method, path, status, body))
  }
}

fn request_ok(
  method: String,
  path: String,
  body: String,
) -> Result(Nil, error.Error) {
  case request(method, path, body) {
    Ok(#(status, response)) -> check_ok(method, path, status, response)
    Error(e) -> Error(e)
  }
}

fn request_json(
  method: String,
  path: String,
  body: json.Json,
) -> Result(String, error.Error) {
  let body_string = json.to_string(body)
  case request(method, path, body_string) {
    Ok(#(200, response)) -> Ok(response)
    Ok(#(201, response)) -> Ok(response)
    Ok(#(status, response)) ->
      Error(error.DockerApiError(method, path, status, response))
    Error(e) -> Error(e)
  }
}

pub fn ping() -> Result(Nil, error.Error) {
  request_ok("GET", "/_ping", "")
}

/// Returns True if the image is already present in the local Docker cache.
pub fn image_exists(image: String) -> Bool {
  let encoded = url_encode(image)
  case request("GET", "/images/" <> encoded <> "/json", "") {
    Ok(#(200, _)) -> True
    _ -> False
  }
}

pub fn pull_image(
  image: String,
  auth: option.Option(config.RegistryAuth),
) -> Result(Nil, error.Error) {
  let ref = image_ref.parse(image)
  let path =
    "/images/create?fromImage="
    <> url_encode(ref.name)
    <> "&tag="
    <> url_encode(ref.tag)
  let headers = case auth {
    Some(a) -> [
      #("Content-Type", "application/json"),
      #("X-Registry-Auth", encode_registry_auth(a)),
    ]
    None -> [#("Content-Type", "application/json")]
  }
  case request_with_headers("POST", path, headers, "") {
    Ok(#(status, body)) if status == 200 ->
      // Docker returns 200 even when the pull fails mid-stream. The body is
      // a sequence of JSON objects, possibly chunked, with progress info or
      // an `error` / `errorDetail` field at the end.
      case scan_pull_stream_for_error(body) {
        Some(reason) -> Error(error.ImagePullFailed(image, reason))
        None -> Ok(Nil)
      }
    Ok(#(status, body)) ->
      Error(error.ImagePullFailed(
        image,
        "HTTP " <> int.to_string(status) <> ": " <> body,
      ))
    Error(e) -> Error(e)
  }
}

// Encode RegistryAuth as the base64-of-JSON value Docker expects in the
// X-Registry-Auth header. Docker accepts either standard or URL-safe
// base64; we use standard base64 (without padding) which is the form
// shown in the official Docker SDK reference.
fn encode_registry_auth(a: config.RegistryAuth) -> String {
  let payload =
    json.object([
      #("username", json.string(a.username)),
      #("password", json.string(cowl.reveal(a.password))),
    ])
  bit_array.base64_encode(<<json.to_string(payload):utf8>>, False)
}

// Single pass: split once on the first `"error":"` marker. If found, take
// the value up to the next `"`. Avoids two scans of the same stream.
fn scan_pull_stream_for_error(stream: String) -> option.Option(String) {
  case string.split_once(stream, "\"error\":\"") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, "\"") {
        Ok(#(msg, _)) -> Some(msg)
        Error(_) -> Some("image pull failed")
      }
    Error(_) -> None
  }
}

pub fn create_container(
  spec: container.ContainerSpec,
) -> Result(String, error.Error) {
  use _ <- result.try(validate_spec(spec))

  let cmd = case container.command(spec) {
    Some(c) -> json.array(c, json.string)
    None -> json.null()
  }

  let entrypoint = case container.entrypoint(spec) {
    Some(e) -> json.array(e, json.string)
    None -> json.null()
  }

  let env_list =
    list.map(container.env(spec), fn(pair) {
      json.string(pair.0 <> "=" <> cowl.reveal(pair.1))
    })

  let port_keys =
    list.map(container.ports(spec), fn(p) {
      int.to_string(port.number(p)) <> "/" <> port.protocol(p)
    })

  let exposed_ports =
    json.object(list.map(port_keys, fn(k) { #(k, json.object([])) }))

  let port_bindings =
    json.object(
      list.map(port_keys, fn(k) {
        #(
          k,
          json.array(
            [
              json.object([
                #("HostIp", json.string("")),
                #("HostPort", json.string("")),
              ]),
            ],
            fn(x) { x },
          ),
        )
      }),
    )

  let binds =
    list.filter_map(container.volumes(spec), fn(v) {
      case container.volume_kind(v) {
        Ok(#(host, cpath, ro)) -> {
          let mode = case ro {
            True -> ":ro"
            False -> ":rw"
          }
          Ok(json.string(host <> ":" <> cpath <> mode))
        }
        Error(_) -> Error(Nil)
      }
    })

  let tmpfs_entries =
    list.filter_map(container.volumes(spec), fn(v) {
      case container.volume_kind(v) {
        Error(cpath) -> Ok(#(cpath, json.string("")))
        Ok(_) -> Error(Nil)
      }
    })

  let labels_obj =
    json.object(
      list.map(container.labels(spec), fn(pair) {
        #(pair.0, json.string(pair.1))
      }),
    )

  let network_mode = case container.network(spec) {
    Some(n) -> json.string(n)
    None -> json.string("bridge")
  }

  let networking_config = case container.network(spec) {
    Some(n) ->
      json.object([
        #("EndpointsConfig", json.object([#(n, json.object([]))])),
      ])
    None -> json.object([])
  }

  let host_config =
    json.object([
      #("PortBindings", port_bindings),
      #("Binds", json.array(binds, fn(x) { x })),
      #("Tmpfs", json.object(tmpfs_entries)),
      #("Privileged", json.bool(container.is_privileged(spec))),
      #("NetworkMode", network_mode),
    ])

  let body =
    json.object([
      #("Image", json.string(container.image(spec))),
      #("Cmd", cmd),
      #("Entrypoint", entrypoint),
      #("Env", json.array(env_list, fn(x) { x })),
      #("ExposedPorts", exposed_ports),
      #("Labels", labels_obj),
      #("HostConfig", host_config),
      #("NetworkingConfig", networking_config),
    ])

  let path = case container.name(spec) {
    Some(n) -> "/containers/create?name=" <> url_encode(n)
    None -> "/containers/create"
  }

  case request_json("POST", path, body) {
    Ok(response) ->
      case json.parse(response, decode.at(["Id"], decode.string)) {
        Ok(id) -> Ok(id)
        Error(_) ->
          Error(error.ContainerCreateFailed(
            container.image(spec),
            "unable to parse create response",
          ))
      }
    Error(error.DockerApiError(_, _, status, body_str)) ->
      Error(error.ContainerCreateFailed(
        container.image(spec),
        "HTTP " <> int.to_string(status) <> ": " <> body_str,
      ))
    Error(e) -> Error(e)
  }
}

fn validate_spec(spec: container.ContainerSpec) -> Result(Nil, error.Error) {
  let image = container.image(spec)
  use _ <- result.try(case contains_crlf(image) {
    True -> Error(error.InvalidImageRef(image))
    False -> Ok(Nil)
  })
  use _ <- result.try(case container.name(spec) {
    Some(n) ->
      case contains_crlf(n) {
        True ->
          Error(error.ContainerCreateFailed(
            image,
            "container name contains CR/LF",
          ))
        False -> Ok(Nil)
      }
    None -> Ok(Nil)
  })
  use _ <- result.try(validate_ports(spec))
  validate_volumes(spec)
}

fn validate_ports(spec: container.ContainerSpec) -> Result(Nil, error.Error) {
  let bad =
    list.find(container.ports(spec), fn(p) {
      let n = port.number(p)
      n < 1 || n > 65_535
    })
  case bad {
    Ok(p) -> Error(error.InvalidPort(port.number(p)))
    Error(Nil) -> Ok(Nil)
  }
}

fn validate_volumes(spec: container.ContainerSpec) -> Result(Nil, error.Error) {
  let bad =
    list.find(container.volumes(spec), fn(v) {
      case container.volume_kind(v) {
        Ok(#(host, cpath, _)) ->
          contains_crlf(host)
          || contains_crlf(cpath)
          || string.contains(host, ":")
        Error(p) -> contains_crlf(p)
      }
    })
  case bad {
    Ok(_) ->
      Error(error.ContainerCreateFailed(
        container.image(spec),
        "volume path invalid (CR/LF or ':' in host path)",
      ))
    Error(Nil) -> Ok(Nil)
  }
}

pub fn start_container(id: String) -> Result(Nil, error.Error) {
  case request("POST", "/containers/" <> id <> "/start", "") {
    Ok(#(status, _)) if status == 204 || status == 304 -> Ok(Nil)
    Ok(#(status, body)) ->
      Error(error.ContainerStartFailed(
        id,
        "HTTP " <> int.to_string(status) <> ": " <> body,
      ))
    Error(error.DockerUnavailable(_, reason)) ->
      Error(error.ContainerStartFailed(id, reason))
    Error(e) -> Error(e)
  }
}

pub fn stop_container(
  id: String,
  timeout_sec: Int,
) -> Result(Nil, error.Error) {
  let path = "/containers/" <> id <> "/stop?t=" <> int.to_string(timeout_sec)
  case request("POST", path, "") {
    // 204 = stopped, 304 = already stopped - both are fine
    Ok(#(status, _)) if status == 204 || status == 304 -> Ok(Nil)
    Ok(#(status, body)) ->
      Error(error.ContainerStopFailed(
        id,
        "HTTP " <> int.to_string(status) <> ": " <> body,
      ))
    Error(error.DockerUnavailable(_, reason)) ->
      Error(error.ContainerStopFailed(id, reason))
    Error(e) -> Error(e)
  }
}

pub fn remove_container(id: String) -> Result(Nil, error.Error) {
  request_ok("DELETE", "/containers/" <> id <> "?force=true", "")
}

pub fn inspect_container(id: String) -> Result(String, error.Error) {
  case request("GET", "/containers/" <> id <> "/json", "") {
    Ok(#(200, response)) -> Ok(response)
    Ok(#(status, response)) ->
      Error(error.DockerApiError(
        "GET",
        "/containers/" <> id <> "/json",
        status,
        response,
      ))
    Error(e) -> Error(e)
  }
}

pub fn container_logs(
  id: String,
  tail: option.Option(Int),
) -> Result(String, error.Error) {
  let tail_q = case tail {
    Some(n) -> "&tail=" <> int.to_string(n)
    None -> "&tail=all"
  }
  case
    request(
      "GET",
      "/containers/" <> id <> "/logs?stdout=1&stderr=1" <> tail_q,
      "",
    )
  {
    Ok(#(200, response)) -> Ok(strip_log_frames(response))
    Ok(#(status, response)) ->
      Error(error.DockerApiError(
        "GET",
        "/containers/" <> id <> "/logs",
        status,
        response,
      ))
    Error(e) -> Error(e)
  }
}

// ---------------------------------------------------------------------------
// Exec
// ---------------------------------------------------------------------------

pub fn exec_container(
  id: String,
  cmd: List(String),
) -> Result(exec.ExecResult, error.Error) {
  let create_body =
    json.object([
      #("Cmd", json.array(cmd, json.string)),
      #("AttachStdout", json.bool(True)),
      #("AttachStderr", json.bool(True)),
    ])

  // Step 1: create exec instance
  use exec_resp <- result.try(
    request_json("POST", "/containers/" <> id <> "/exec", create_body)
    |> result.map_error(fn(e) {
      case e {
        error.DockerApiError(_, _, status, body) ->
          error.ExecFailed(
            id,
            cmd,
            -1,
            "create exec HTTP " <> int.to_string(status) <> ": " <> body,
          )
        _ -> e
      }
    }),
  )
  use exec_id <- result.try(
    case json.parse(exec_resp, decode.at(["Id"], decode.string)) {
      Ok(eid) -> Ok(eid)
      Error(_) ->
        Error(error.ExecFailed(
          id,
          cmd,
          -1,
          "unable to parse exec create response",
        ))
    },
  )

  // Step 2: start exec (blocking - returns multiplexed stdout+stderr stream)
  let start_body =
    json.object([#("Detach", json.bool(False)), #("Tty", json.bool(False))])
  use raw <- result.try(
    case
      request(
        "POST",
        "/exec/" <> exec_id <> "/start",
        json.to_string(start_body),
      )
    {
      Ok(#(200, body)) -> Ok(body)
      Ok(#(status, body)) ->
        Error(error.ExecFailed(
          id,
          cmd,
          -1,
          "start exec HTTP " <> int.to_string(status) <> ": " <> body,
        ))
      Error(e) -> Error(e)
    },
  )

  let #(stdout, stderr) = split_log_streams(raw)

  // Step 3: inspect exec to get exit code (real error if decode fails)
  use exit_code <- result.try(
    case request("GET", "/exec/" <> exec_id <> "/json", "") {
      Ok(#(200, body)) ->
        case json.parse(body, decode.at(["ExitCode"], decode.int)) {
          Ok(code) -> Ok(code)
          Error(_) ->
            Error(error.ExecFailed(
              id,
              cmd,
              -1,
              "unable to parse exec inspect response",
            ))
        }
      Ok(#(status, body)) ->
        Error(error.ExecFailed(
          id,
          cmd,
          -1,
          "inspect exec HTTP " <> int.to_string(status) <> ": " <> body,
        ))
      Error(e) -> Error(e)
    },
  )

  Ok(exec.ExecResult(exit_code, stdout, stderr))
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

pub fn create_network(name: String) -> Result(String, error.Error) {
  case contains_crlf(name) {
    True ->
      Error(error.DockerApiError(
        "POST",
        "/networks/create",
        0,
        "network name contains CR/LF",
      ))
    False -> {
      let body =
        json.object([
          #("Name", json.string(name)),
          #("Driver", json.string("bridge")),
        ])
      case request_json("POST", "/networks/create", body) {
        Ok(response) ->
          case json.parse(response, decode.at(["Id"], decode.string)) {
            Ok(nid) -> Ok(nid)
            Error(_) ->
              Error(error.DockerApiError(
                "POST",
                "/networks/create",
                0,
                "parse error",
              ))
          }
        Error(e) -> Error(e)
      }
    }
  }
}

pub fn remove_network(id: String) -> Result(Nil, error.Error) {
  request_ok("DELETE", "/networks/" <> id, "")
}

// ---------------------------------------------------------------------------
// File copy
// ---------------------------------------------------------------------------

/// Copies a file from the host into a running container.
/// Uses erl_tar to create a tar archive in a temp file, then PUTs it to
/// the Docker Engine API at PUT /containers/{id}/archive.
pub fn copy_file_to(
  container_id: String,
  host_path: String,
  container_path: String,
) -> Result(Nil, error.Error) {
  case
    contains_crlf(container_id)
    || contains_crlf(host_path)
    || contains_crlf(container_path)
  {
    True -> Error(error.FileCopyFailed(container_path, "path contains CR/LF"))
    False ->
      case transport_copy_file(container_id, host_path, container_path) {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> Error(error.FileCopyFailed(container_path, reason))
      }
  }
}
