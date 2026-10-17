-module(testcontainer_lifecycle).
-export([with_cleanup/2]).

%% Preserve callback process affinity. Catchable errors/exits/throws must
%% release the resource and then retain their original reason and stack.
with_cleanup(Body, Cleanup) ->
    BodyResult = try Body()
    catch Class:Reason:Stack ->
        try Cleanup() catch _:_ -> ok end,
        erlang:raise(Class, Reason, Stack)
    end,
    CleanupResult = Cleanup(),
    case {BodyResult, CleanupResult} of
        {{ok, _}, {error, Error}} -> {error, Error};
        _ -> BodyResult
    end.
