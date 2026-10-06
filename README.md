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

## Local development and agents

On Debian/Ubuntu or macOS, run the same installer implementation outside GitHub
Actions. Prerequisites are Bash, Git, Node.js 20+, and an existing Go 1.21+
launcher; dependency installation also needs sudo/root or Homebrew respectively.
No npm install is needed: the checked-in bundle is ready to run.

```bash
git clone https://github.com/xgo-dev/setup-llgo.git ../setup-llgo
LLGO_VERSION=main GO_VERSION=1.27.0 bash ../setup-llgo/scripts/install.sh
# Run the exact `source .../env.sh` command printed by the installer.
llgo version
llgo test -v ./...
```

`LLGO_VERSION` accepts the same selectors as `llgo-version` (default: latest
stable release). `GO_VERSION` is an exact patch version, defaulting to the
current directory's go.mod `go` directive, or 1.27.0 if absent. Set it explicitly
when the project uses an older Go than the selected LLGo compiler requires.
The Go module proxy supplies the toolchain; its real `bin/go`, not an older
toolchain-switching launcher, is activated with `GOTOOLCHAIN=local`.

Other overrides are `LLVM_VERSION` (22), `INSTALL_METHOD` (auto),
`INSTALL_DEPENDENCIES` (true), and `LLGO_INSTALL_ROOT` (`~/.cache/setup-llgo`).
Each invocation owns a new installation directory and writes an `env.sh` there;
it never resets another checkout or changes shell profiles. `GH_TOKEN` or
`GITHUB_TOKEN` is optional for release metadata. In CI, the action additionally
provides setup-go caching; the standalone entrypoint does not implement a second
cache manager. Native Windows setup remains available through the action.

When setting `INSTALL_DEPENDENCIES=false`, provide the required native libraries
and put the matching LLVM's `bin` directory on `PATH`
before running the installer.

Both entrypoints share Unix dependency setup. On Debian/Ubuntu, CA certificates
already present only in the system trust bundle are registered as local sources
before apt can regenerate that bundle. Managed certificates (including disabled
ones) are not promoted to local trust. Missing OpenSSL, malformed certificates,
or bundle-only non-CA certificates fail before apt; TLS verification is never
disabled. This preserves existing administrator trust, not certificates supplied
by the project, and cannot restore a CA that was already lost.

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
| `llgo-version` | Empty (latest stable tag) | Selector described above |
| `llgo-version-file` | Empty | Plain selector file or `// llgo <selector>` in go.mod/go.work; explicit version takes precedence |
| `install-method` | `auto` | `auto`, `release`, or `source` |
| `go-version` | `1.27` when neither Go input is supplied | Go toolchain version |
| `go-version-file` | Empty | Version file passed to actions/setup-go |
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

Release metadata and archive transfers retry transient connection failures and
timeouts up to three attempts, with 1s/2s backoff. HTTP errors, invalid checksums
and local filesystem failures fail immediately.

The installation stays in a unique directory under `RUNNER_TEMP`; existing user
work directories are never removed. `PATH` and `LLGO_ROOT` are exported for later
steps. Go caching includes LLGo's dependency files and, for source builds, its
resolved Git HEAD. The action requires Node.js 20+ and Git on `PATH`; CI tests
Node.js 20 and 24 on Linux, macOS and Windows. Self-hosted runners must also
provide `tar` (including ZIP support on Windows).

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
