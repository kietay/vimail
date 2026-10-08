# Vendored dependencies

| Package | Version | License | Why vendored |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | v1.20.0 | MIT (`SwiftTerm/LICENSE`) | Terminal view that hosts your real `nvim`/`vim` in the compose editor (Ctrl+G). Vendored so the app builds offline and without fetching SwiftTerm's tool and benchmark dependencies. |

Changes from upstream: removed tests, benchmarks, docs and tool targets; replaced the build-info
plugin with the static `Sources/SwiftTerm/SwiftTermBuildInfo.swift`; trimmed `Package.swift`; excluded `Apple/Metal/Shaders.metal` from the build (the Metal renderer is
opt-in and its shader compiler only ships with Xcode).
