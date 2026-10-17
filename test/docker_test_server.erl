-module(docker_test_server).
-export([with_responses/2, with_observed_responses/3]).

%% Tests use a real TCP connection to exercise the HTTP client without a
%% Docker daemon. Always restore the process-wide environment on failure.
with_responses(Responses, Body) ->
    with_observed_responses(Responses, fun(_) -> nil end, Body).

with_observed_responses(Responses, OnRequest, Body) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false},
                                      {ip, {127, 0, 0, 1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    Original = os:getenv("DOCKER_HOST"),
    Parent = self(),
    Tag = make_ref(),
    Server = spawn(fun() -> serve(Listener, Responses, Parent, Tag, OnRequest) end),
    os:putenv("DOCKER_HOST", "tcp://127.0.0.1:" ++ integer_to_list(Port)),
    try
        Result = Body(),
        {Result, collect(Tag, [])}
    after
        case Original of
            false -> os:unsetenv("DOCKER_HOST");
            Value -> os:putenv("DOCKER_HOST", Value)
        end,
        gen_tcp:close(Listener),
        exit(Server, kill)
    end.

serve(Listener, Responses, Parent, Tag, OnRequest) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            case read_request(Socket, <<>>) of
                {ok, Request} ->
                    Parent ! {Tag, Request},
                    OnRequest(Request),
                    {Status, Body, Delay, Rest} = next_response(Responses),
                    timer:sleep(Delay),
                    gen_tcp:send(Socket, [
                        "HTTP/1.1 ", integer_to_binary(Status), " Test\r\n",
                        "Content-Length: ", integer_to_binary(byte_size(Body)),
                        "\r\nConnection: close\r\n\r\n", Body
                    ]),
                    gen_tcp:close(Socket),
                    serve(Listener, Rest, Parent, Tag, OnRequest);
                _ ->
                    %% A deadline may cancel a connection before its complete
                    %% request arrives. Keep accepting subsequent test calls.
                    gen_tcp:close(Socket),
                    serve(Listener, Responses, Parent, Tag, OnRequest)
            end;
        _ -> ok
    end.

next_response([{Status, Body, Delay} | Rest]) -> {Status, Body, Delay, Rest};
next_response([]) -> {500, <<"unexpected request">>, 0, []}.

read_request(Socket, Data) ->
    case binary:split(Data, <<"\r\n\r\n">>) of
        [Head, Body] ->
            Lines = binary:split(Head, <<"\r\n">>, [global]),
            [RequestLine | Headers] = Lines,
            Length = content_length(Headers),
            case byte_size(Body) >= Length of
                true -> {ok, RequestLine};
                false -> recv_request(Socket, Data)
            end;
        _ -> recv_request(Socket, Data)
    end.

recv_request(Socket, Data) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, More} -> read_request(Socket, <<Data/binary, More/binary>>);
        Error -> Error
    end.

content_length([]) -> 0;
content_length([<<"Content-Length: ", N/binary>> | _]) -> binary_to_integer(N);
content_length([_ | Rest]) -> content_length(Rest).

collect(Tag, Acc) ->
    receive
        {Tag, Request} -> collect(Tag, [Request | Acc])
    after 0 -> lists:reverse(Acc)
    end.
