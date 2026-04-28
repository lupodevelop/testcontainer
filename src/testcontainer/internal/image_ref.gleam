import gleam/list
import gleam/string

pub type ImageRef {
  ImageRef(name: String, tag: String)
}

/// Splits an image reference into `(name, tag)`. Falls back to
/// `tag = "latest"` when no tag is present.
///
/// Heuristic: a Docker tag may contain `[A-Za-z0-9._-]` but never `/`.
/// The trailing colon-segment is treated as a tag only when it has no
/// `/`. With this rule the parse is unambiguous in every case except a
/// bare `host:port` reference: e.g. `registry:5000` is parsed as
/// `name="registry", tag="5000"`. To force the registry-port
/// interpretation, append the image segment - `registry:5000/image[:tag]` -
/// which the parser detects via the `/` in the second-to-last segment.
pub fn parse(raw: String) -> ImageRef {
  let parts = string.split(raw, ":")
  case list.reverse(parts) {
    [potential_tag, name_part, ..rest_reversed] -> {
      // A tag never contains "/". If the last colon-segment does, the whole
      // string is the name with no explicit tag (e.g. "registry:5000/image").
      case string.contains(potential_tag, "/") {
        True -> ImageRef(name: raw, tag: "latest")
        False ->
          case string.contains(name_part, "/") {
            True -> {
              let name =
                string.join(list.reverse([name_part, ..rest_reversed]), ":")
              ImageRef(name: name, tag: potential_tag)
            }
            False -> {
              let name =
                string.join(
                  list.append(list.reverse(rest_reversed), [name_part]),
                  ":",
                )
              ImageRef(name: name, tag: potential_tag)
            }
          }
      }
    }
    _ -> ImageRef(name: raw, tag: "latest")
  }
}
