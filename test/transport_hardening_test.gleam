import gleeunit/should
import testcontainer/internal/docker

@external(erlang, "docker_transport", "parse_response")
fn parse_binary_response(data: BitArray) -> Result(#(Int, String), String)

pub fn non_utf8_header_value_does_not_panic_test() {
  parse_binary_response(<<
    "HTTP/1.1 200 OK\r\nX-Test: ":utf8,
    255,
    "\r\n\r\n":utf8,
  >>)
  |> should.equal(Ok(#(200, "")))
}

pub fn non_ascii_transfer_encoding_returns_error_test() {
  parse_binary_response(<<
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: ":utf8,
    255,
    "\r\n\r\n":utf8,
  >>)
  |> should.be_error()
}

pub fn plain_hex_prefix_is_preserved_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nabc\r\nhello!",
  )
  |> should.equal(Ok(#(200, "abc\r\nhello!")))
}

pub fn chunked_header_is_case_insensitive_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\ntRaNsFeR-EnCoDiNg: ChUnKeD\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
  )
  |> should.equal(Ok(#(200, "abc")))
}

pub fn chunk_extensions_and_trailers_are_decoded_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;foo=bar\r\nabc\r\n0\r\nX-Checksum: fine\r\n\r\n",
  )
  |> should.equal(Ok(#(200, "abc")))
}

pub fn chunked_empty_body_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
  )
  |> should.equal(Ok(#(200, "")))
}

pub fn truncated_chunk_is_rejected_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabc",
  )
  |> should.be_error()
}

pub fn missing_chunk_terminator_is_rejected_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n",
  )
  |> should.be_error()
}

pub fn truncated_chunk_trailers_are_rejected_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Foo: bar\r\n",
  )
  |> should.be_error()
}

pub fn non_hex_chunk_size_is_rejected_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n",
  )
  |> should.be_error()
}

pub fn invalid_status_returns_error_instead_of_panicking_test() {
  docker.parse_response("HTTP/1.1 oops Bad\r\n\r\n") |> should.be_error()
}

pub fn invalid_protocol_is_rejected_test() {
  docker.parse_response("NOTHTTP 200 OK\r\n\r\n") |> should.be_error()
}

pub fn truncated_content_length_is_rejected_test() {
  docker.parse_response("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc")
  |> should.be_error()
}

pub fn conflicting_framing_is_rejected_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
  )
  |> should.be_error()
}

pub fn duplicate_content_length_is_rejected_test() {
  docker.parse_response(
    "HTTP/1.1 200 OK\r\nContent-Length: 3\r\ncontent-length: 5\r\n\r\nabc",
  )
  |> should.be_error()
}

pub fn malformed_header_is_rejected_test() {
  docker.parse_response("HTTP/1.1 200 OK\r\nno-colon\r\n\r\nabc")
  |> should.be_error()
}

pub fn interim_response_is_skipped_test() {
  docker.parse_response(
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
  )
  |> should.equal(Ok(#(200, "OK")))
}
