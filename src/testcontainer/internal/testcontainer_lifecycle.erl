-module(testcontainer_lifecycle).
-export([with_standalone/3]).

%% The guard owns both acquisition and release. In particular, killing the
%% caller cannot interrupt an acquisition or a release already in progress.
%% The user body still executes in the caller's process.
with_standalone(Acquire, Body, Release) ->
    Owner = self(),
    Tag = make_ref(),
    {Guard, Monitor} = spawn_monitor(fun() ->
        standalone_guard(Owner, Tag, Acquire, Release)
    end),
    try
        case await_guard(Guard, Monitor, Tag, acquired) of
            {ok, Output} ->
                with_cleanup(fun() -> Body(Output) end, fun() ->
                    release_guard(Guard, Tag)
                end);
            {error, _} = Error -> Error
        end
    after
        erlang:demonitor(Monitor, [flush])
    end.

standalone_guard(Owner, Tag, Acquire, Release) ->
    Monitor = erlang:monitor(process, Owner),
    try
        receive
            {'DOWN', Monitor, process, Owner, _} -> ok
        after 0 ->
            case capture(Acquire) of
                {ok, _} = Acquired ->
                    %% A callback may itself receive monitor messages. Check
                    %% liveness in case Acquire consumed the owner's DOWN.
                    case erlang:is_process_alive(Owner) of
                        false ->
                            _ = capture(Release),
                            ok;
                        true ->
                            Owner ! {Tag, acquired, Acquired},
                            receive
                                {Tag, release} ->
                                    Result = capture(Release),
                                    Owner ! {Tag, released, Result};
                                {'DOWN', Monitor, process, Owner, _} ->
                                    %% No live caller can receive cleanup errors.
                                    _ = capture(Release),
                                    ok
                            end
                    end;
                Failed -> Owner ! {Tag, acquired, Failed}
            end
        end
    after
        erlang:demonitor(Monitor, [flush])
    end.

release_guard(Guard, Tag) ->
    %% Body may have consumed the original guard DOWN. A fresh monitor makes
    %% waiting safe even if the guard has already died during the callback.
    Monitor = erlang:monitor(process, Guard),
    try
        Guard ! {Tag, release},
        await_guard(Guard, Monitor, Tag, released)
    after
        erlang:demonitor(Monitor, [flush])
    end.

await_guard(Guard, Monitor, Tag, Phase) ->
    receive
        {Tag, Phase, {raised, Class, Reason, Stack}} ->
            erlang:raise(Class, Reason, Stack);
        {Tag, Phase, Result} -> Result;
        {'DOWN', Monitor, process, Guard, Reason} ->
            exit({standalone_guard_down, Reason})
    end.

capture(Callback) ->
    try Callback()
    catch Class:Reason:Stack -> {raised, Class, Reason, Stack}
    end.

%% Catchable body errors/exits/throws release the resource before retaining
%% their original reason and stack, including if release also fails.
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
