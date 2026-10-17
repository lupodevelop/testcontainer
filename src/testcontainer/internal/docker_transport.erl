-module(docker_transport).
-export([request/4, parse_response/1,
         tcp_can_connect/2, http_get_status/3,
         now_ms/0, sleep_ms/1,
         with_deadline/2,
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
                      deadline_timeout(?CONNECT_TIMEOUT));
    {tcp, Host, Port} ->
      gen_tcp:connect(Host, Port,
                      [binary, {active, false}, {packet, raw}],
                      deadline_timeout(?CONNECT_TIMEOUT))
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
  case deadline_timeout(?RECV_TIMEOUT) of
    0 -> {error, timeout};
    Timeout ->
      case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data}      -> recv_all(Socket, [Acc, Data]);
        {error, closed} -> {ok, iolist_to_binary(Acc)};
        {error, Reason} -> {error, Reason}
      end
  end.

parse_response(Data) when is_list(Data) ->
  parse_response(iolist_to_binary(Data));
parse_response(Data) ->
  %% The FFI promises a Result, including for malformed daemon/proxy data.
  try parse_http_response(Data)
  catch
    error:badarg -> {error, <<"malformed HTTP response">>}
  end.

parse_http_response(Data) ->
  case binary:split(Data, <<"\r\n\r\n">>) of
    [Head, RawBody] ->
      [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
      case {parse_status(StatusLine), parse_headers(HeaderLines, [])} of
        {{ok, Code}, {ok, _}} when Code >= 100, Code < 200, Code =/= 101 ->
          parse_http_response(RawBody);
        {{ok, Code}, {ok, Headers}} ->
          case response_body(Headers, RawBody) of
            {ok, Body} -> {ok, {Code, Body}};
            Error -> Error
          end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
      end;
    _ -> {error, <<"incomplete HTTP response">>}
  end.

parse_status(Line) ->
  case binary:split(Line, <<" ">>, [global]) of
    [Version, <<A, B, C>> = Code | _]
        when (Version =:= <<"HTTP/1.1">> orelse Version =:= <<"HTTP/1.0">>),
             A >= $1, A =< $5, B >= $0, B =< $9, C >= $0, C =< $9 ->
      {ok, binary_to_integer(Code)};
    _ -> {error, <<"bad HTTP status line">>}
  end.

parse_headers([], Acc) -> {ok, Acc};
parse_headers([Line | Rest], Acc) ->
  case binary:split(Line, <<":">>) of
    [Name, Value] when Name =/= <<>> ->
      %% Reject whitespace in field names and obsolete folded headers.
      case re:run(Name, <<"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$">>, [{capture, none}]) of
        match ->
          Header = {ascii_lower(Name), trim_ows(Value)},
          parse_headers(Rest, [Header | Acc]);
        nomatch -> {error, <<"bad HTTP header name">>}
      end;
    _ -> {error, <<"bad HTTP header">>}
  end.

response_body(Headers, Body) ->
  Transfer = [ascii_lower(V) || {<<"transfer-encoding">>, V} <- Headers],
  Lengths = [V || {<<"content-length">>, V} <- Headers],
  case {Transfer, Lengths} of
    {[], []} -> {ok, Body};
    {[], [Length]} ->
      case re:run(Length, <<"^[0-9]+$">>, [{capture, none}]) of
        match ->
          case binary_to_integer(Length) =:= byte_size(Body) of
            true -> {ok, Body};
            false -> {error, <<"HTTP Content-Length mismatch">>}
          end;
        nomatch -> {error, <<"invalid HTTP Content-Length">>}
      end;
    {[<<"chunked">>], []} -> dechunk_body(Body, []);
    _ -> {error, <<"ambiguous or unsupported HTTP body framing">>}
  end.

%% HTTP field values are bytes, not necessarily UTF-8. Only ASCII case and
%% optional SP/HTAB whitespace have meaning to the framing parser.
ascii_lower(Bin) ->
  << <<(lower_byte(C))>> || <<C>> <= Bin >>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

trim_ows(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> trim_ows(Rest);
trim_ows(Bin) -> trim_ows_right(Bin).

trim_ows_right(<<>>) -> <<>>;
trim_ows_right(Bin) ->
  Size = byte_size(Bin) - 1,
  case Bin of
    <<Rest:Size/binary, C>> when C =:= $\s; C =:= $\t -> trim_ows_right(Rest);
    _ -> Bin
  end.

%% Decode only when Transfer-Encoding says chunked. Require all bytes and
%% the terminating chunk, rather than reporting a partial response as success.
dechunk_body(Data, Acc) ->
  case binary:split(Data, <<"\r\n">>) of
    [SizeLine, Rest] ->
      [SizeBin | _] = binary:split(SizeLine, <<";">>),
      case re:run(SizeBin, <<"^[0-9a-fA-F]+$">>, [{capture, none}]) of
        match -> decode_chunk(binary_to_integer(SizeBin, 16), Rest, Acc);
        nomatch -> {error, <<"invalid HTTP chunk size">>}
      end;
    _ -> {error, <<"incomplete HTTP chunk size">>}
  end.

decode_chunk(0, Rest, Acc) ->
  case validate_trailers(Rest) of
    ok -> {ok, iolist_to_binary(lists:reverse(Acc))};
    Error -> Error
  end;
decode_chunk(Size, Rest, Acc) ->
  case Rest of
    <<Chunk:Size/binary, "\r\n", Next/binary>> ->
      dechunk_body(Next, [Chunk | Acc]);
    _ -> {error, <<"incomplete HTTP chunk data">>}
  end.

validate_trailers(<<"\r\n">>) -> ok;
validate_trailers(Rest) ->
  case binary:split(Rest, <<"\r\n\r\n">>) of
    [TrailerBlock, <<>>] ->
      case parse_headers(binary:split(TrailerBlock, <<"\r\n">>, [global]), []) of
        {ok, Headers} ->
          case lists:any(fun({Name, _}) ->
              Name =:= <<"content-length">> orelse Name =:= <<"transfer-encoding">>
            end, Headers) of
            true -> {error, <<"framing field in HTTP trailers">>};
            false -> ok
          end;
        Error -> Error
      end;
    _ -> {error, <<"incomplete or trailing HTTP chunk data">>}
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
  case gen_tcp:connect(Host, Port, [binary, {active, false}], deadline_timeout(2000)) of
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
  case gen_tcp:connect(Host, Port, [binary, {active, false}, {packet, raw}],
                       deadline_timeout(2000)) of
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
  timer:sleep(deadline_timeout(Ms)),
  nil.

%% Scope a readiness deadline to the current process. All nested Docker and
%% readiness socket calls share the remaining budget without changing their
%% public signatures. Restore it even when a callback raises an exception.
with_deadline(Deadline, Body) ->
  Key = '$testcontainer_deadline',
  Previous = get(Key),
  Effective = case Previous of
    undefined -> Deadline;
    Existing -> min(Existing, Deadline)
  end,
  put(Key, Effective),
  try Body()
  after
    case Previous of
      undefined -> erase(Key);
      _ -> put(Key, Previous)
    end
  end.

deadline_timeout(Default) ->
  case get('$testcontainer_deadline') of
    undefined -> Default;
    Deadline -> max(0, min(Default, Deadline - now_ms()))
  end.

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
