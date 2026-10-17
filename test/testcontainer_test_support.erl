-module(testcontainer_test_support).
-export([with_cleanup/2, catch_exception/1, with_env/3, await_exit/2,
         consume_down/2]).

%% Model user callbacks that receive monitor messages themselves.
consume_down(Pid, Timeout) ->
    receive
        {'DOWN', _, process, Pid, _} -> true
    after Timeout -> false
    end.

await_exit(Pid, Timeout) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {'DOWN', Monitor, process, Pid, _} -> true
    after Timeout ->
        erlang:demonitor(Monitor, [flush]),
        false
    end.

with_env(Name, Value, Body) ->
    Key = binary_to_list(Name),
    Original = os:getenv(Key),
    os:putenv(Key, binary_to_list(Value)),
    try Body()
    after
        case Original of
            false -> os:unsetenv(Key);
            Previous -> os:putenv(Key, Previous)
        end
    end.

with_cleanup(Cleanup, Body) ->
    try Body() after Cleanup() end.

catch_exception(Body) ->
    try {ok, Body()}
    catch Class:Reason ->
        {error, iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.
