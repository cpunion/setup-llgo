import { platformFor, releaseAsset } from '../src/platform'

it.each([
  ['linux', 'amd64', '', 'linux-amd64.tar.gz'],
  ['linux', 'arm64', '', 'linux-arm64.tar.gz'],
  ['darwin', 'amd64', '', 'darwin-amd64.tar.gz'],
  ['darwin', 'arm64', '', 'darwin-arm64.tar.gz'],
  ['win32', 'amd64', 'msvc', 'windows-amd64-msvc.zip'],
  ['win32', 'amd64', 'mingw', 'windows-amd64-mingw.zip'],
  ['win32', 'arm64', 'msvc', 'windows-arm64-msvc.zip'],
  ['win32', 'arm64', 'mingw', 'windows-arm64-mingw.zip']
])('selects %s/%s/%s', (os, arch, abi, asset) => {
  expect(releaseAsset('v1.0.4', platformFor(os, arch, abi))).toBe(
    `llgo1.0.4.${asset}`
  )
})
it.each(['x64', 'X64', 'x86_64'])('normalizes %s', arch => {
  expect(platformFor('linux', arch, '').arch).toBe('amd64')
})
it.each([
  ['freebsd', 'amd64', ''],
  ['linux', '386', ''],
  ['win32', 'amd64', 'invalid']
])('rejects %s/%s/%s', (os, arch, abi) => {
  expect(() => platformFor(os, arch, abi)).toThrow()
})
