import testcontainer/container
import testcontainer/error

/// A Formula combines a ContainerSpec with a typed extraction function.
///
/// When `testcontainer.with_formula/2` starts the container it calls
/// `extract` on the running Container to produce a service-specific output
/// type (e.g. `PostgresContainer`, `RedisContainer`).
///
/// Formulas are defined in the companion package `testcontainer_formulas`,
/// not in this core package. The core only defines the type and the lifecycle
/// entry point.
///
///   use pg <- testcontainer.with_formula(postgres.formula(config))
///   // pg has type PostgresContainer with .connection_url, .host, .port, …
///
pub opaque type Formula(output) {
  Formula(
    spec: container.ContainerSpec,
    extract: fn(container.Container) -> Result(output, error.Error),
  )
}

/// Create a Formula from a ContainerSpec and an extraction function.
/// Called by formula modules (e.g. `testcontainer_formulas/postgres`).
pub fn new(
  spec: container.ContainerSpec,
  extract: fn(container.Container) -> Result(output, error.Error),
) -> Formula(output) {
  Formula(spec: spec, extract: extract)
}

// Internal accessors - used only by `testcontainer.gleam`. Marked
// `@internal` so they are not part of the published API surface, but are
// still accessible to the core package.

@internal
pub fn spec(f: Formula(output)) -> container.ContainerSpec {
  f.spec
}

@internal
pub fn extract(
  f: Formula(output),
  c: container.Container,
) -> Result(output, error.Error) {
  f.extract(c)
}
