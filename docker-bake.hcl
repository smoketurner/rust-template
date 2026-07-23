# Sample bake file for the static musl build (Dockerfile.build).
# Invoke a target per architecture, setting TARGET to the musl triple:
#   TARGET=aarch64-unknown-linux-musl docker buildx bake ci
# Binaries land under ./target/<TARGET>/release/ (output type=local).

variable "TARGET" {
  default = ""
}

variable "SOURCE_DATE_EPOCH" {
  default = "0"
}

variable "GENERATE_SBOM" {
  default = "false"
}

group "default" {
  targets = ["ci"]
}

target "_common" {
  dockerfile = "Dockerfile.build"
  context    = "."
  output     = ["type=local,dest=."]
}

# Build every distributable binary (used by CI).
target "ci" {
  inherits = ["_common"]
  args = {
    TARGET            = TARGET
    CARGO_PACKAGES    = "-p app-cli -p app-server"
    SOURCE_DATE_EPOCH = "0"
    GENERATE_SBOM     = "false"
  }
  cache-from = ["type=gha,scope=bake-ci-${TARGET}"]
  cache-to   = ["type=gha,mode=max,ignore-error=true,scope=bake-ci-${TARGET}"]
}

# Build only the CLI binary.
target "cli" {
  inherits = ["_common"]
  args = {
    TARGET            = TARGET
    CARGO_PACKAGES    = "-p app-cli"
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
    GENERATE_SBOM     = GENERATE_SBOM
  }
  cache-from = ["type=gha,scope=bake-cli-${TARGET}"]
  cache-to   = ["type=gha,mode=max,ignore-error=true,scope=bake-cli-${TARGET}"]
}

# Build only the server binary (run `make css-build` first).
target "server" {
  inherits = ["_common"]
  args = {
    TARGET            = TARGET
    CARGO_PACKAGES    = "-p app-server"
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
    GENERATE_SBOM     = GENERATE_SBOM
  }
  cache-from = ["type=gha,scope=bake-server-${TARGET}"]
  cache-to   = ["type=gha,mode=max,ignore-error=true,scope=bake-server-${TARGET}"]
}
