import gleeunit/should
import testcontainer/error
import testcontainer/internal/docker
import testcontainer/internal/wait_runner
import testcontainer/wait

@external(erlang, "docker_test_server", "with_responses")
fn with_responses(
  responses: List(#(Int, String, Int)),
  body: fn() -> a,
) -> #(a, List(String))

@external(erlang, "docker_transport", "now_ms")
fn now_ms() -> Int

pub fn slow_inspect_cannot_succeed_past_wait_deadline_test() {
  let #(#(outcome, elapsed), _) =
    with_responses(
      [#(200, "{\"NetworkSettings\":{\"Ports\":{}}}", 600), #(200, "ready", 0)],
      fn() {
        let start = now_ms()
        let outcome =
          wait_runner.run(
            wait.log("ready") |> wait.with_timeout(50),
            "owned",
            "127.0.0.1",
          )
        #(outcome, now_ms() - start)
      },
    )
  assert_timeout(outcome)
  { elapsed < 400 } |> should.be_true()
}

pub fn slow_command_cannot_exceed_wait_deadline_test() {
  let #(#(outcome, elapsed), _) =
    with_responses(
      [
        #(200, "{\"NetworkSettings\":{\"Ports\":{}}}", 0),
        #(201, "{\"Id\":\"exec-id\"}", 0),
        #(200, "", 600),
        #(200, "{\"ExitCode\":0}", 0),
      ],
      fn() {
        let start = now_ms()
        let outcome =
          wait_runner.run(
            wait.command(["slow"]) |> wait.with_timeout(50),
            "owned",
            "127.0.0.1",
          )
        #(outcome, now_ms() - start)
      },
    )
  assert_timeout(outcome)
  { elapsed < 400 } |> should.be_true()
}

pub fn timed_out_wait_does_not_poison_following_docker_calls_test() {
  let #(#(outcome, ping), _) =
    with_responses(
      [#(200, "{\"NetworkSettings\":{\"Ports\":{}}}", 100), #(200, "OK", 50)],
      fn() {
        let outcome =
          wait_runner.run(
            wait.log("ready") |> wait.with_timeout(30),
            "owned",
            "127.0.0.1",
          )
        #(outcome, docker.ping())
      },
    )
  case outcome {
    Error(error.WaitTimedOut(_, _)) -> Nil
    _ ->
      outcome |> should.equal(Error(error.WaitTimedOut("expected timeout", 30)))
  }
  ping |> should.equal(Ok(Nil))
}

fn assert_timeout(outcome: Result(Nil, error.Error)) {
  case outcome {
    Error(error.WaitTimedOut(_, elapsed)) ->
      { elapsed >= 50 } |> should.be_true()
    _ ->
      outcome |> should.equal(Error(error.WaitTimedOut("expected timeout", 50)))
  }
}
