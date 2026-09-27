# setup-llgo

Install LLGo on Linux, macOS and Windows. Releases use SHA-256-verified
precompiled archives when available; branches and commits build from source.
Go, LLVM and native runtime dependencies are installed for the selected host.

```yaml
- uses: actions/checkout@v7
- uses: xgo-dev/setup-llgo@main
  with:
    llgo-version: main
    go-version: '1.27'
    llvm-version: '22'
- run: llgo test -v ./...
```

## Selecting LLGo

| Input | Selection |
| --- | --- |
| `v1.0.4` or `1.0.4` | Exact tag |
| `v1.0`, `1.0`, `1` | Highest stable version with that prefix |
| `1.0.x`, `v1.0.*`, `^1.0.3`, `>=1.0 <1.1` | Highest version satisfying the SemVer range |
| `v1.0.?`, `v2.0.0-rc.*` | Matching tag using `*` and `?` globs |
| `main`, `release/1.0` | Exact branch |
| `release/*` | A unique matching branch; ambiguous matches fail |
| `refs/heads/main`, `refs/tags/v1.0.4` | Explicit ref |
| Full commit SHA or 7+ hexadecimal characters | Exact commit; unknown/ambiguous abbreviations fail |
| Empty or `latest` | Highest stable release tag |

Exact tags take precedence over exact branches; explicit `refs/heads/` removes
ambiguity. Version patterns select by semantic version, not lexicographic order.
Prereleases require an explicit prerelease version/range or a matching tag glob.
Annotated tags resolve to their commit. Abbreviated commits require fetching
history, so full SHAs are faster. Branches and version patterns are resolved
remotely on every run; the resolved full SHA is logged and available as output.

## Inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `llgo-version` | `latest` | Selector described above |
| `install-method` | `auto` | `auto`, `release`, or `source` |
| `go-version` | `1.27` | Go toolchain version |
| `llvm-version` | `22` | LLVM major version; Windows currently uses 22 |
| `architecture` | Runner architecture | Native `amd64`/`x64` or `arm64` |
| `windows-abi` | `msvc` | `msvc` or `mingw` |
| `install-dependencies` | `true` | Set `false` when the matching LLVM/SDK/runtime dependencies are already configured |
| `cache` | `true` | Restore/save Go module and build caches |
| `cache-dependency-path` | `go.sum` | Additional project dependency files for the cache key |
| `check-latest` | `false` | Check for the latest matching Go toolchain |
| `token` | `github.token` | GitHub API and Go download authentication |

`auto` downloads the matching release asset if one exists, otherwise builds the
resolved commit. `release` fails if the asset is unavailable; `source` always
builds from source. Network/authentication failures and checksum mismatches fail
installation instead of silently switching methods. Older LLGo versions may need
explicit compatible Go and LLVM versions.

The installation stays in a unique directory under `RUNNER_TEMP`; existing user
work directories are never removed. `PATH` and `LLGO_ROOT` are exported for later
steps. Go caching includes LLGo's dependency files and, for source builds, its
resolved Git HEAD. Hosted runners supply Node.js 20+ and Git; self-hosted runners
must provide them, plus `tar` (including ZIP support on Windows).

## Platforms and validation

CI installs both a release archive and `main` on all eight native combinations:

- Linux amd64 and arm64 (Ubuntu/glibc).
- macOS amd64 and arm64.
- Windows amd64 and arm64, each with MSVC and MinGW ABIs.

Each combination runs `llgo test`, builds and executes a sample program, and
Windows jobs check the native target triple. Separate jobs test version prefixes,
ranges, glob patterns, full commits and abbreviated commits. Unit tests use local
Git fixtures and mocked downloads; they never install software into the user's
home directory. The Windows setup is adapted from LLGo's own CI; see
`THIRD_PARTY_NOTICES.md`.

Outputs: `llgo-version`, `llgo-version-verified` (whether a tag was selected),
`llgo-revision`, `llgo-ref`, `install-method`, `go-version`, and `cache-hit`.
