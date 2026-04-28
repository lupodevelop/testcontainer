-module(docker_transport).
-export([request/4, parse_response/1,
         tcp_can_connect/2, http_get_status/3,
         now_ms/0, sleep_ms/1,
         strip_log_frames/1, split_log_streams/1,
         copy_file_to_container/3,
         socket_path/0, docker_endpoint/0]).

%% Raw HTTP/1.1 over the Docker daemon socket.
%%
%% Two transports are supported, selected via the DOCKER_HOST env var:
%%
%%   - unix://<path>  → Unix domain socket via gen_tcp:{local, Path}
%%   - tcp://host:port → plain TCP connect to host:port
%%
%% Default: unix:///var/run/docker.sock (when DOCKER_HOST is unset).
%% No TLS support - TCP transports must be plain HTTP. For HTTPS Docker
%% endpoints the user is expected to terminate TLS upstream.

-define(DEFAULT_SOCKET, "/var/run/docker.sock").
-define(RECV_TIMEOUT, 30000).
-define(CONNECT_TIMEOUT, 5000).

%% Legacy alias kept for callers that only need the unix path.
socket_path() ->
  case docker_endpoint() of
    {unix, Path} -> Path;
    _            -> ?DEFAULT_SOCKET
  end.

%% Resolve the Docker endpoint from DOCKER_HOST.
%% Returns: {unix, Path :: string()} | {tcp, Host :: string(), Port :: integer()}.
docker_endpoint() ->
  case os:getenv("DOCKER_HOST") of
    false -> {unix, ?DEFAULT_SOCKET};
    "" -> {unix, ?DEFAULT_SOCKET};
    "unix://" ++ Rest -> {unix, Rest};
    "tcp://" ++ Rest -> parse_tcp(Rest);
    "/" ++ _ = Raw -> {unix, Raw};
    _Other -> {unix, ?DEFAULT_SOCKET}
  end.

parse_tcp(HostPort) ->
  case string:split(HostPort, ":") of
    [H, P] ->
      case string:to_integer(P) of
        {Int, ""} when is_integer(Int) -> {tcp, H, Int};
        _ -> {unix, ?DEFAULT_SOCKET}
      end;
    [H] -> {tcp, H, 2375};
    _ -> {unix, ?DEFAULT_SOCKET}
  end.

connect_endpoint() ->
  case docker_endpoint() of
    {unix, Path} ->
      gen_tcp:connect({local, Path}, 0,
                      [binary, {active, false}, {packet, raw}],
                      ?CONNECT_TIMEOUT);
    {tcp, Host, Port} ->
      gen_tcp:connect(Host, Port,
                      [binary, {active, false}, {packet, raw}],
                      ?CONNECT_TIMEOUT)
  end.

endpoint_label() ->
  case docker_endpoint() of
    {unix, Path}      -> Path;
    {tcp, Host, Port} -> Host ++ ":" ++ integer_to_list(Port)
  end.

request(Method, Path, Headers, Body) ->
  case connect_endpoint() of
    {ok, Socket} ->
      Result = try
        do_http_request(Socket, Method, Path, Headers, Body)
      after
        gen_tcp:close(Socket)
      end,
      Result;
    {error, Reason} ->
      {error, list_to_binary(
        io_lib:format("connect ~s: ~p", [endpoint_label(), Reason]))}
  end.

do_http_request(Socket, Method, Path, Headers, Body) ->
  BodyBin = to_binary(Body),
  MethodBin = method_bin(Method),
  ContentLength = byte_size(BodyBin),
  HeaderLines = format_headers(Headers),
  Request = iolist_to_binary([
    MethodBin, " ", Path, " HTTP/1.1\r\n",
    "Host: localhost\r\n",
    "Content-Length: ", integer_to_binary(ContentLength), "\r\n",
    HeaderLines,
    "Connection: close\r\n",
    "\r\n",
    BodyBin
  ]),
  case gen_tcp:send(Socket, Request) of
    ok ->
      case recv_all(Socket, []) of
        {ok, RawResp} -> parse_response(RawResp);
        {error, Err}  -> {error, list_to_binary(io_lib:format("recv: ~p", [Err]))}
      end;
    {error, Err} ->
      {error, list_to_binary(io_lib:format("send: ~p", [Err]))}
  end.

%% Accumulate as iolist, concat once at end (avoid O(n^2) binary grow).
recv_all(Socket, Acc) ->
  case gen_tcp:recv(Socket, 0, ?RECV_TIMEOUT) of
    {ok, Data}      -> recv_all(Socket, [Acc, Data]);
    {error, closed} -> {ok, iolist_to_binary(Acc)};
    {error, Reason} -> {error, Reason}
  end.

parse_response(Data) when is_list(Data) ->
  parse_response(iolist_to_binary(Data));
parse_response(Data) ->
  case binary:split(Data, <<"\r\n\r\n">>) of
    [Head, RawBody] ->
      case binary:split(Head, <<"\r\n">>) of
        [StatusLine | _] ->
          case binary:split(StatusLine, <<" ">>, [global]) of
            [_, CodeBin | _] ->
              Code = binary_to_integer(CodeBin),
              Body = dechunk(RawBody),
              {ok, {Code, Body}};
            _ ->
              {error, <<"bad status line">>}
          end;
        _ ->
          {error, <<"bad response head">>}
      end;
    _ ->
      {error, <<"incomplete HTTP response">>}
  end.

%% Decode HTTP chunked transfer encoding.
%% If the body does not start with a hex chunk-size line, returns it unchanged.
dechunk(Body) ->
  case re:run(Body, <<"^[0-9a-fA-F]+\r\n">>) of
    {match, _} -> dechunk_body(Body, []);
    nomatch    -> Body
  end.

dechunk_body(<<"0\r\n", _/binary>>, Acc) -> iolist_to_binary(Acc);
dechunk_body(Data, Acc) ->
  case binary:split(Data, <<"\r\n">>) of
    [SizeBin, Rest] ->
      Size = binary_to_integer(SizeBin, 16),
      case Size of
        0 -> iolist_to_binary(Acc);
        _ ->
          case Rest of
            <<Chunk:Size/binary, "\r\n", Next/binary>> ->
              dechunk_body(Next, [Acc, Chunk]);
            _ ->
              iolist_to_binary([Acc, Rest])
          end
      end;
    _ -> iolist_to_binary(Acc)
  end.

method_bin(Method) when is_atom(Method)   -> atom_to_binary(Method, utf8);
method_bin(Method) when is_binary(Method) -> Method;
method_bin(Method) when is_list(Method)   -> list_to_binary(Method).

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L)   -> list_to_binary(L);
to_binary(_)                   -> <<>>.

format_headers(Headers) ->
  iolist_to_binary([[K, ": ", V, "\r\n"] || {K, V} <- Headers]).

%% ---------------------------------------------------------------------------
%% copy_file_to_container/3
%%
%% Reads HostPath from disk, wraps it in a minimal tar archive, and PUTs it
%% to the Docker Engine API at /containers/{Id}/archive?path={ContainerDir}.
%% The file appears in the container at ContainerPath.
%%
%% Returns ok | {error, Reason :: binary()}.
%% ---------------------------------------------------------------------------

copy_file_to_container(ContainerId, HostPath, ContainerPath)
    when is_binary(ContainerId) ->
  copy_file_to_container(binary_to_list(ContainerId), HostPath, ContainerPath);
copy_file_to_container(ContainerId, HostPath, ContainerPath)
    when is_binary(HostPath) ->
  copy_file_to_container(ContainerId, binary_to_list(HostPath), ContainerPath);
copy_file_to_container(ContainerId, HostPath, ContainerPath)
    when is_binary(ContainerPath) ->
  copy_file_to_container(ContainerId, HostPath, binary_to_list(ContainerPath));
copy_file_to_container(ContainerId, HostPath, ContainerPath) ->
  case has_crlf(ContainerPath) orelse has_crlf(ContainerId) of
    true ->
      {error, <<"path contains CR/LF">>};
    false ->
      ContainerDir  = filename:dirname(ContainerPath),
      FileBaseName  = filename:basename(ContainerPath),
      TmpTar = unique_tmp_path("tc_", ".tar"),
      Result = case erl_tar:open(TmpTar, [write]) of
        {ok, Tar} ->
          case erl_tar:add(Tar, HostPath, FileBaseName, []) of
            ok ->
              case erl_tar:close(Tar) of
                ok ->
                  case file:read_file(TmpTar) of
                    {ok, TarBin} ->
                      put_tar(ContainerId, ContainerDir, TarBin);
                    {error, ReadErr} ->
                      {error, list_to_binary(io_lib:format("read tar: ~p", [ReadErr]))}
                  end;
                {error, CloseErr} ->
                  {error, list_to_binary(io_lib:format("close tar: ~p", [CloseErr]))}
              end;
            {error, AddErr} ->
              erl_tar:close(Tar),
              {error, list_to_binary(io_lib:format("add to tar: ~p", [AddErr]))}
          end;
        {error, OpenErr} ->
          {error, list_to_binary(io_lib:format("open tar: ~p", [OpenErr]))}
      end,
      file:delete(TmpTar),
      Result
  end.

has_crlf(S) when is_list(S) ->
  lists:any(fun(C) -> C =:= $\r orelse C =:= $\n end, S);
has_crlf(B) when is_binary(B) ->
  has_crlf(binary_to_list(B));
has_crlf(_) -> false.

%% Build a tmp filename unlikely to collide across processes or BEAM nodes
%% sharing the same TMPDIR. Composed of: OS pid + microsecond timestamp +
%% per-node unique integer. Honours $TMPDIR when set, falls back to /tmp.
unique_tmp_path(Prefix, Suffix) ->
  TmpDir = case os:getenv("TMPDIR") of
    false       -> "/tmp";
    ""          -> "/tmp";
    Dir         -> Dir
  end,
  Pid    = os:getpid(),
  Time   = integer_to_list(erlang:system_time(microsecond)),
  Uniq   = integer_to_list(erlang:unique_integer([positive])),
  Name   = Prefix ++ Pid ++ "_" ++ Time ++ "_" ++ Uniq ++ Suffix,
  filename:join(TmpDir, Name).

%% PUT a tar binary to /containers/{Id}/archive?path={Dir}.
put_tar(ContainerId, ContainerDir, TarBin) ->
  EncodedDir = query_encode(ContainerDir),
  Path = iolist_to_binary([
    "/containers/", ContainerId, "/archive?path=", EncodedDir
  ]),
  case connect_endpoint() of
    {ok, Socket} ->
      ContentLength = byte_size(TarBin),
      Request = iolist_to_binary([
        "PUT ", Path, " HTTP/1.1\r\n",
        "Host: localhost\r\n",
        "Content-Type: application/x-tar\r\n",
        "Content-Length: ", integer_to_binary(ContentLength), "\r\n",
        "Connection: close\r\n",
        "\r\n",
        TarBin
      ]),
      Result = try
        case gen_tcp:send(Socket, Request) of
          ok ->
            case recv_all(Socket, []) of
              {ok, RawResp} ->
                case parse_response(RawResp) of
                  {ok, {200, _}} -> {ok, nil};
                  {ok, {Status, Body}} ->
                    {error, list_to_binary(
                      io_lib:format("HTTP ~p: ~s", [Status, Body]))};
                  {error, E} -> {error, E}
                end;
              {error, Err} ->
                {error, list_to_binary(io_lib:format("recv: ~p", [Err]))}
            end;
          {error, Err} ->
            {error, list_to_binary(io_lib:format("send: ~p", [Err]))}
        end
      after
        gen_tcp:close(Socket)
      end,
      Result;
    {error, Reason} ->
      {error, list_to_binary(
        io_lib:format("connect ~s: ~p", [endpoint_label(), Reason]))}
  end.

%% Percent-encode characters that are special in URL query strings.
%% Keeps "/" unchanged (it is already inside a path segment here).
query_encode(S) when is_list(S) ->
  list_to_binary(lists:flatmap(fun query_encode_char/1, S)).

query_encode_char($/) -> "/";
query_encode_char($ ) -> "%20";
query_encode_char($&) -> "%26";
query_encode_char($=) -> "%3D";
query_encode_char($+) -> "%2B";
query_encode_char($?) -> "%3F";
query_encode_char($#) -> "%23";
query_encode_char($\r) -> "%0D";
query_encode_char($\n) -> "%0A";
query_encode_char(C)  -> [C].

%% ---------------------------------------------------------------------------
%% Wait strategy helpers
%% ---------------------------------------------------------------------------

%% Try a TCP connect to Host:Port. Returns ok | {error, Reason}.
tcp_can_connect(Host, Port) when is_binary(Host) ->
  tcp_can_connect(binary_to_list(Host), Port);
tcp_can_connect(Host, Port) ->
  case gen_tcp:connect(Host, Port, [binary, {active, false}], 2000) of
    {ok, Sock} ->
      gen_tcp:close(Sock),
      {ok, nil};
    {error, Reason} ->
      {error, list_to_binary(io_lib:format("~p", [Reason]))}
  end.

%% Perform an HTTP GET to Host:Port/Path, return {ok, StatusCode} or {error, Reason}.
http_get_status(Host, Port, Path) when is_binary(Host) ->
  http_get_status(binary_to_list(Host), Port, Path);
http_get_status(Host, Port, Path) ->
  case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}], 2000) of
    {ok, Sock} ->
      PathBin = to_binary(Path),
      Req = iolist_to_binary([
        "GET ", PathBin, " HTTP/1.1\r\n",
        "Host: ", Host, ":", integer_to_list(Port), "\r\n",
        "Connection: close\r\n",
        "\r\n"
      ]),
      Result = case gen_tcp:send(Sock, Req) of
        ok ->
          case recv_all(Sock, []) of
            {ok, Resp} ->
              case parse_response(Resp) of
                {ok, {Code, _}} -> {ok, Code};
                {error, E}      -> {error, E}
              end;
            {error, E} -> {error, list_to_binary(io_lib:format("recv: ~p", [E]))}
          end;
        {error, E} -> {error, list_to_binary(io_lib:format("send: ~p", [E]))}
      end,
      gen_tcp:close(Sock),
      Result;
    {error, Reason} ->
      {error, list_to_binary(io_lib:format("connect: ~p", [Reason]))}
  end.

%% Current time in milliseconds (monotonic).
now_ms() ->
  erlang:monotonic_time(millisecond).

%% Sleep for Ms milliseconds.
sleep_ms(Ms) ->
  timer:sleep(Ms),
  nil.

%% Strip Docker multiplexed log stream framing - concatenated stdout+stderr.
%% Each frame: 1 byte type | 3 bytes padding | 4 bytes size (big-endian) | <size> bytes data
strip_log_frames(<<>>) -> <<>>;
strip_log_frames(<<_Type:8, _Pad:24, Size:32/big, Rest/binary>>) ->
  case Size =< byte_size(Rest) of
    true ->
      <<Frame:Size/binary, Next/binary>> = Rest,
      <<Frame/binary, (strip_log_frames(Next))/binary>>;
    false ->
      Rest
  end;
strip_log_frames(Data) -> Data.

%% Split Docker multiplexed exec output into {Stdout, Stderr}.
%% Type byte: 1 = stdout, 2 = stderr (0 = stdin, ignored).
split_log_streams(Data) ->
  {Out, Err} = split_loop(Data, [], []),
  {iolist_to_binary(Out), iolist_to_binary(Err)}.

split_loop(<<>>, Out, Err) -> {Out, Err};
split_loop(<<Type:8, _Pad:24, Size:32/big, Rest/binary>>, Out, Err) ->
  case Size =< byte_size(Rest) of
    true ->
      <<Frame:Size/binary, Next/binary>> = Rest,
      case Type of
        1 -> split_loop(Next, [Out, Frame], Err);
        2 -> split_loop(Next, Out, [Err, Frame]);
        _ -> split_loop(Next, Out, Err)
      end;
    false ->
      %% Truncated frame - append remainder to stdout as best-effort.
      {[Out, Rest], Err}
  end;
split_loop(Data, Out, Err) ->
  %% No frame header - treat everything as stdout (e.g. when TTY=true).
  {[Out, Data], Err}.
