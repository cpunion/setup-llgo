import fs from 'fs'
import os from 'os'
import path from 'path'
import {
  parseRemoteRefs,
  resolveVersion,
  RemoteRef,
  versionInput,
  verifyInstalledVersion
} from '../src/resolve'

const refs: RemoteRef[] = [
  ...['v0.9.8', 'v1.0.3', 'v1.0.4', 'v1.1.0', 'v2.0.0-rc.1'].map((name, i) => ({
    name,
    sha: String(i).repeat(40),
    kind: 'tag' as const
  })),
  ...['main', 'release/1.0', 'feature/foo', 'feature/bar'].map(name => ({
    name,
    sha: 'a'.repeat(40),
    kind: 'branch' as const
  }))
]
describe('LLGo ref resolution', () => {
  it.each([
    ['1.0.4', 'v1.0.4'],
    ['v1.0.4', 'v1.0.4'],
    ['1.0', 'v1.0.4'],
    ['v1.0', 'v1.0.4'],
    ['v0.9', 'v0.9.8'],
    ['1', 'v1.1.0'],
    ['1.0.x', 'v1.0.4'],
    ['v1.0.*', 'v1.0.4'],
    ['v1.0.?', 'v1.0.4'],
    ['^1.0.3', 'v1.1.0'],
    ['>=1.0 <1.1', 'v1.0.4'],
    ['', 'v1.1.0'],
    ['latest', 'v1.1.0'],
    ['*', 'v1.1.0'],
    ['v2.0.0-rc.*', 'v2.0.0-rc.1'],
    ['v2.0.0-rc.1', 'v2.0.0-rc.1'],
    ['refs/tags/v1.0.4', 'v1.0.4']
  ])('resolves %s to %s', (spec, tag) => {
    expect(resolveVersion(spec, refs).ref).toBe(`refs/tags/${tag}`)
  })
  it.each(['main', 'release/1.0', 'release/*', 'refs/heads/release/1.0'])(
    'resolves branch %s',
    spec => {
      expect(resolveVersion(spec, refs).kind).toBe('branch')
    }
  )
  it.each(['abc1234', 'b'.repeat(40)])('accepts commit %s', sha => {
    expect(resolveVersion(sha, refs)).toEqual({ kind: 'commit', ref: sha, sha })
  })
  it.each([
    'missing',
    '9.9',
    'feature/*',
    'refs/heads/missing',
    '$(touch /tmp/no)',
    '--help'
  ])('rejects invalid or ambiguous %s', spec => {
    expect(() => resolveVersion(spec, refs)).toThrow()
  })
  it('peels annotated tags without fabricating a v prefix', () => {
    const parsed = parseRemoteRefs(
      `${'a'.repeat(40)}\trefs/tags/1.2.3\n${'b'.repeat(
        40
      )}\trefs/tags/1.2.3^{}\n${'c'.repeat(40)}\trefs/heads/main\n`
    )
    expect(resolveVersion('1.2', parsed)).toEqual({
      ref: 'refs/tags/1.2.3',
      sha: 'b'.repeat(40),
      kind: 'tag'
    })
  })
})

it('reads version files and honors explicit version precedence', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'llgo-version-file-'))
  try {
    const plain = path.join(dir, '.llgo-version')
    fs.writeFileSync(plain, 'release/1.0\n')
    expect(versionInput('', plain)).toBe('release/1.0')
    const mod = path.join(dir, 'go.mod')
    fs.writeFileSync(mod, 'module example\n// llgo v1.0.*\n')
    expect(versionInput('', mod)).toBe('v1.0.*')
    expect(versionInput('main', 'missing')).toBe('main')
    expect(versionInput('', '')).toBe('')
    fs.writeFileSync(mod, 'module example\n')
    expect(() => versionInput('', mod)).toThrow('No // llgo')
    fs.writeFileSync(plain, '')
    expect(() => versionInput('', plain)).toThrow('Empty')
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
it('validates the installed release patch version', () => {
  expect(() =>
    verifyInstalledVersion('llgo v1.0.4 darwin/arm64', 'refs/tags/v1.0.4')
  ).not.toThrow()
  expect(() =>
    verifyInstalledVersion('llgo v1.0.3 darwin/arm64', 'refs/tags/v1.0.4')
  ).toThrow('does not match')
})
