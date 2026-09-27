# Third-party notices

The Windows dependency and ABI activation steps in `action.yml`,
`scripts/windows/`, and `scripts/pacman_retry*.sh` are adapted from
[xgo-dev/llgo at 7db1409](https://github.com/xgo-dev/llgo/tree/7db1409073f28bf13a35ae0a3ea663eba010fd73/.github).
They are licensed under Apache-2.0; see `LICENSES/llgo.txt`.
Paths were adjusted to resolve within this action, and the native installation
matrix excludes the upstream 32-bit cross-target setup.

Bundled JavaScript dependency notices are in `dist/licenses.txt`.
