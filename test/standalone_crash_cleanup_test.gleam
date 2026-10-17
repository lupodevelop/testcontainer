import gleam/erlang/process
import gleam/string
import gleeunit/should
import testcontainer
import testcontainer/formula

@external(erlang, "testcontainer_test_support", "await_exit")
fn await_exit(pid: process.Pid, timeout: Int) -> Bool

@external(erlang, "testcontainer_test_support", "catch_exception")
fn catch_exception(body: fn() -> a) -> Result(a, String)

@external(erlang, "testcontainer_test_support", "consume_down")
fn consume_down(pid: process.Pid, timeout: Int) -> Bool

pub fn standalone_releases_after_owner_is_killed_test() {
  let ready = process.new_subject()
  let released = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let f =
        formula.new_standalone(fn() { Ok("resource") }, fn() {
          process.send(released, process.self())
          Ok(Nil)
        })
      testcontainer.with_standalone_formula(f, fn(_) {
        process.send(ready, process.self())
        let blocker: process.Subject(Nil) = process.new_subject()
        process.receive_forever(blocker)
        Ok(Nil)
      })
    })
  let started = process.receive(ready, 1000)
  process.kill(owner)
  await_exit(owner, 1000) |> should.be_true()
  started |> should.equal(Ok(owner))
  let guard = process.receive(released, 1000) |> should.be_ok()
  await_exit(guard, 1000) |> should.be_true()
  process.receive(released, 0) |> should.be_error()
}

pub fn standalone_finishes_acquire_and_releases_after_owner_is_killed_test() {
  let acquiring = process.new_subject()
  let released = process.new_subject()
  let body_called = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let f =
        formula.new_standalone(
          fn() {
            let resume: process.Subject(Nil) = process.new_subject()
            process.send(acquiring, #(process.self(), resume))
            process.receive_forever(resume)
            Ok("resource")
          },
          fn() {
            process.send(released, process.self())
            Ok(Nil)
          },
        )
      testcontainer.with_standalone_formula(f, fn(_) {
        process.send(body_called, Nil)
        Ok(Nil)
      })
    })
  let started = process.receive(acquiring, 1000)
  process.kill(owner)
  await_exit(owner, 1000) |> should.be_true()
  let #(guard, resume) = started |> should.be_ok()
  process.send(resume, Nil)
  let finished = process.receive(released, 1000)
  // Also unblock/stop workers on failure, before raising the assertion.
  case finished {
    Error(_) -> process.kill(guard)
    Ok(_) -> Nil
  }
  finished |> should.equal(Ok(guard))
  await_exit(guard, 1000) |> should.be_true()
  process.receive(body_called, 0) |> should.be_error()
  process.receive(released, 0) |> should.be_error()
}

pub fn standalone_release_survives_owner_killed_during_release_test() {
  let releasing = process.new_subject()
  let released = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let f =
        formula.new_standalone(fn() { Ok("resource") }, fn() {
          let resume: process.Subject(Nil) = process.new_subject()
          process.send(releasing, #(process.self(), resume))
          process.receive_forever(resume)
          process.send(released, Nil)
          Ok(Nil)
        })
      testcontainer.with_standalone_formula(f, fn(_) { Ok(Nil) })
    })
  let started = process.receive(releasing, 1000)
  process.kill(owner)
  await_exit(owner, 1000) |> should.be_true()
  let #(guard, resume) = started |> should.be_ok()
  process.send(resume, Nil)
  let finished = process.receive(released, 1000)
  case finished {
    Error(_) -> process.kill(guard)
    Ok(_) -> Nil
  }
  finished |> should.equal(Ok(Nil))
  await_exit(guard, 1000) |> should.be_true()
  process.receive(releasing, 0) |> should.be_error()
}

pub fn standalone_callbacks_share_guard_and_body_stays_in_caller_test() {
  let released = process.new_subject()
  let caller = process.self()
  let f =
    formula.new_standalone(fn() { Ok(process.self()) }, fn() {
      process.send(released, process.self())
      Ok(Nil)
    })
  let #(acquire_pid, body_pid) =
    testcontainer.with_standalone_formula(f, fn(acquire_pid) {
      Ok(#(acquire_pid, process.self()))
    })
    |> should.be_ok()
  let release_pid = process.receive(released, 1000) |> should.be_ok()
  body_pid |> should.equal(caller)
  release_pid |> should.equal(acquire_pid)
  { acquire_pid != caller } |> should.be_true()
  await_exit(acquire_pid, 1000) |> should.be_true()
}

pub fn standalone_failed_acquisition_skips_body_and_release_test() {
  let invoked = process.new_subject()
  let f =
    formula.new_standalone(fn() { Error("acquire failed") }, fn() {
      process.send(invoked, "release")
      Ok(Nil)
    })
  testcontainer.with_standalone_formula(f, fn(_) {
    process.send(invoked, "body")
    Ok(Nil)
  })
  |> should.equal(Error("acquire failed"))
  process.receive(invoked, 0) |> should.be_error()
}

pub fn standalone_acquire_exception_is_propagated_without_release_test() {
  let acquiring = process.new_subject()
  let released = process.new_subject()
  let f =
    formula.new_standalone(
      fn() {
        process.send(acquiring, process.self())
        panic as "acquisition-panic"
      },
      fn() {
        process.send(released, Nil)
        Ok(Nil)
      },
    )
  let message =
    catch_exception(fn() {
      testcontainer.with_standalone_formula(f, fn(_) { Ok(Nil) })
    })
    |> should.be_error()
  string.contains(message, "acquisition-panic") |> should.be_true()
  let guard = process.receive(acquiring, 1000) |> should.be_ok()
  await_exit(guard, 1000) |> should.be_true()
  process.receive(released, 0) |> should.be_error()
}

pub fn standalone_release_exception_is_propagated_after_body_success_test() {
  let released = process.new_subject()
  let f =
    formula.new_standalone(fn() { Ok(Nil) }, fn() {
      process.send(released, process.self())
      panic as "release-panic"
    })
  let message =
    catch_exception(fn() {
      testcontainer.with_standalone_formula(f, fn(_) { Ok(Nil) })
    })
    |> should.be_error()
  string.contains(message, "release-panic") |> should.be_true()
  let guard = process.receive(released, 1000) |> should.be_ok()
  await_exit(guard, 1000) |> should.be_true()
  process.receive(released, 0) |> should.be_error()
}

pub fn standalone_body_error_wins_over_release_error_test() {
  let released = process.new_subject()
  let f =
    formula.new_standalone(fn() { Ok(Nil) }, fn() {
      process.send(released, process.self())
      Error("release failed")
    })
  testcontainer.with_standalone_formula(f, fn(_) { Error("body failed") })
  |> should.equal(Error("body failed"))
  let guard = process.receive(released, 1000) |> should.be_ok()
  await_exit(guard, 1000) |> should.be_true()
  process.receive(released, 0) |> should.be_error()
}

pub fn standalone_reports_guard_death_instead_of_waiting_forever_test() {
  let f = formula.new_standalone(fn() { Ok(process.self()) }, fn() { Ok(Nil) })
  let message =
    catch_exception(fn() {
      testcontainer.with_standalone_formula(f, fn(guard) {
        process.kill(guard)
        await_exit(guard, 1000) |> should.be_true()
        Ok(Nil)
      })
    })
    |> should.be_error()
  string.contains(message, "standalone_guard_down") |> should.be_true()
}

pub fn standalone_releases_when_acquire_consumes_owner_down_test() {
  let acquiring = process.new_subject()
  let released = process.new_subject()
  let consumed = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let caller = process.self()
      let f =
        formula.new_standalone(
          fn() {
            process.send(acquiring, process.self())
            process.send(consumed, consume_down(caller, 1000))
            Ok("resource")
          },
          fn() {
            process.send(released, process.self())
            Ok(Nil)
          },
        )
      testcontainer.with_standalone_formula(f, fn(_) { Ok(Nil) })
    })
  let started = process.receive(acquiring, 1000)
  process.kill(owner)
  await_exit(owner, 1000) |> should.be_true()
  let guard = started |> should.be_ok()
  let owner_down = process.receive(consumed, 1000)
  let finished = process.receive(released, 1000)
  case finished {
    Error(_) -> process.kill(guard)
    Ok(_) -> Nil
  }
  owner_down |> should.equal(Ok(True))
  finished |> should.equal(Ok(guard))
  await_exit(guard, 1000) |> should.be_true()
}

pub fn standalone_reports_guard_death_even_if_body_consumes_down_test() {
  let finished = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let f =
        formula.new_standalone(fn() { Ok(process.self()) }, fn() { Ok(Nil) })
      let outcome =
        catch_exception(fn() {
          testcontainer.with_standalone_formula(f, fn(guard) {
            process.kill(guard)
            consume_down(guard, 1000) |> should.be_true()
            Ok(Nil)
          })
        })
      process.send(finished, outcome)
    })
  let outcome = process.receive(finished, 1000)
  process.kill(owner)
  let message = outcome |> should.be_ok() |> should.be_error()
  string.contains(message, "standalone_guard_down") |> should.be_true()
}
