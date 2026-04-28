/// Every error returned by the public API is one of these variants.
/// Each carries enough context to diagnose the problem without scraping logs.
pub type Error {
  /// The Docker daemon could not be reached on the configured socket.
  DockerUnavailable(socket_path: String, reason: String)

  /// The image could not be pulled (network error, auth required, not found).
  ImagePullFailed(image: String, reason: String)

  /// `POST /containers/create` returned an error or the response could not
  /// be parsed.
  ContainerCreateFailed(image: String, reason: String)

  /// `POST /containers/{id}/start` returned an error.
  ContainerStartFailed(container_id: String, reason: String)

  /// `POST /containers/{id}/stop` returned an error.
  ContainerStopFailed(container_id: String, reason: String)

  /// A wait strategy did not succeed within its configured timeout.
  /// `elapsed_ms` is the actual elapsed wall-clock time.
  WaitTimedOut(strategy_description: String, elapsed_ms: Int)

  /// A wait strategy reported a transient failure (the poll loop will retry
  /// until the deadline; this variant is also returned when the deadline is
  /// reached without success for non-timeout reasons).
  WaitFailed(strategy_description: String, reason: String)

  /// An exec call failed at the Docker API level (not to be confused with
  /// a non-zero exit code, which is returned via `exec.ExecResult`).
  ExecFailed(
    container_id: String,
    cmd: List(String),
    exit_code: Int,
    stderr: String,
  )

  /// The requested container port is not in the spec's port mapping.
  PortNotMapped(container_port: Int)

  /// `copy_file_to/3` failed (read error, tar error, HTTP error).
  FileCopyFailed(path: String, reason: String)

  /// Docker inspect JSON was received but `NetworkSettings.Ports` could not be
  /// decoded into a usable host-port mapping.
  PortMappingParseFailed(container_id: String, reason: String)

  /// A Docker Engine API call returned an unexpected non-2xx status that
  /// did not map to a more specific variant above.
  DockerApiError(method: String, path: String, status: Int, body: String)

  /// The given image reference is malformed (currently used for CR/LF
  /// validation; reserved for future stricter parsing).
  InvalidImageRef(raw: String)

  /// A port number outside the valid TCP/UDP range (1..=65535).
  InvalidPort(number: Int)
}
