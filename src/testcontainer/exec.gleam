/// The result of running a command inside a container via
/// `testcontainer.exec/2`.
///
/// `stdout` and `stderr` are returned separately when the command runs
/// without a TTY (the default). For TTY exec calls the combined output
/// arrives in `stdout`.
pub type ExecResult {
  ExecResult(exit_code: Int, stdout: String, stderr: String)
}

/// True iff the command exited with status 0.
pub fn succeeded(result: ExecResult) -> Bool {
  case result {
    ExecResult(code, _, _) -> code == 0
  }
}

/// Returns `stdout <> stderr`, useful when the caller only cares about
/// the combined human-readable output.
pub fn output(result: ExecResult) -> String {
  case result {
    ExecResult(_, stdout, stderr) -> stdout <> stderr
  }
}
