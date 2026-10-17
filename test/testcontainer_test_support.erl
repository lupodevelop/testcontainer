-module(testcontainer_test_support).
-export([with_cleanup/2, catch_exception/1, with_env/3]).

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
