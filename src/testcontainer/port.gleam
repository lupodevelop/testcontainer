import testcontainer/error

/// A container port together with its protocol.
/// Build with `tcp/1` / `udp/1` (panic-free, but trust the caller to pass
/// a valid number) or `try_tcp/1` / `try_udp/1` (validated `Result`).
pub opaque type Port {
  Tcp(Int)
  Udp(Int)
}

/// Creates a TCP port. Numbers outside `1..=65535` will be rejected later
/// by `start/1`. For up-front validation, prefer `try_tcp/1`.
pub fn tcp(number: Int) -> Port {
  Tcp(number)
}

/// Creates a UDP port. See `tcp/1` for validation notes.
pub fn udp(number: Int) -> Port {
  Udp(number)
}

/// Validated TCP port constructor.
pub fn try_tcp(number: Int) -> Result(Port, error.Error) {
  case number >= 1 && number <= 65_535 {
    True -> Ok(Tcp(number))
    False -> Error(error.InvalidPort(number))
  }
}

/// Validated UDP port constructor.
pub fn try_udp(number: Int) -> Result(Port, error.Error) {
  case number >= 1 && number <= 65_535 {
    True -> Ok(Udp(number))
    False -> Error(error.InvalidPort(number))
  }
}

/// Returns the port number.
pub fn number(port: Port) -> Int {
  case port {
    Tcp(n) -> n
    Udp(n) -> n
  }
}

/// Returns `"tcp"` or `"udp"`.
pub fn protocol(port: Port) -> String {
  case port {
    Tcp(_) -> "tcp"
    Udp(_) -> "udp"
  }
}
