import { execFileSync } from 'child_process'
import { createHash } from 'crypto'
import fs from 'fs'
import os from 'os'
import path from 'path'
import * as core from '@actions/core'
import * as downloads from '../src/download'
import { checkoutLLGo, installRelease, archiveTool } from '../src/install'
import { parseRemoteRefs, resolveVersion, Selection } from '../src/resolve'

let root: string
beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-llgo-test-'))
})
afterEach(() => {
  jest.restoreAllMocks()
  fs.rmSync(root, { recursive: true, force: true })
})
function git(args: string[], cwd: string): string {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  }).trim()
}
it('checks out a tag, a branch, full SHA and an old abbreviated SHA in isolated paths', () => {
  const repo = path.join(root, 'repo')
  fs.mkdirSync(repo)
  git(['init', '-b', 'main'], repo)
  git(['config', 'user.name', 'test'], repo)
  git(['config', 'user.email', 'test@example.invalid'], repo)
  fs.writeFileSync(path.join(repo, 'fixture'), 'first')
  git(['add', '.'], repo)
  git(['commit', '-m', 'first'], repo)
  const first = git(['rev-parse', 'HEAD'], repo)
  git(['tag', '-a', 'v1.0.4', '-m', 'release'], repo)
  fs.writeFileSync(path.join(repo, 'fixture'), 'second')
  git(['commit', '-am', 'second'], repo)
  const head = git(['rev-parse', 'HEAD'], repo)
  const refs = parseRemoteRefs(
    git(['ls-remote', '--heads', '--tags', repo], root)
  )
  const sentinel = path.join(root, 'workdir')
  fs.mkdirSync(sentinel)
  fs.writeFileSync(path.join(sentinel, 'keep'), 'untouched')
  for (const [spec, want] of [
    ['v1.0.4', first],
    ['main', head],
    [first, first],
    [first.slice(0, 8), first]
  ]) {
    const dest = fs.mkdtempSync(path.join(root, 'install 空格 '))
    expect(checkoutLLGo(resolveVersion(spec, refs), dest, repo)).toBe(want)
    expect(git(['rev-parse', 'HEAD'], dest)).toBe(want)
  }
  expect(fs.readFileSync(path.join(sentinel, 'keep'), 'utf8')).toBe('untouched')
})

const release: Selection = {
  kind: 'tag',
  ref: 'refs/tags/v1.0.4',
  sha: 'a'.repeat(40)
}
const platform = { os: 'linux', arch: 'amd64', abi: '' }
it('falls back only when a release or matching asset is absent', async () => {
  jest.spyOn(core, 'getInput').mockReturnValue('')
  const fetchMock = jest.spyOn(global, 'fetch')
  fetchMock.mockResolvedValueOnce(new Response('', { status: 404 }))
  expect(await installRelease(release, platform, root)).toBe(false)
  fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ assets: [] })))
  expect(await installRelease(release, platform, root)).toBe(false)
  expect(
    await installRelease({ ...release, kind: 'branch' }, platform, root)
  ).toBe(false)
  expect(fetchMock).toHaveBeenCalledTimes(2)
})
it('does not hide API failures behind source fallback', async () => {
  jest.spyOn(core, 'getInput').mockReturnValue('')
  jest
    .spyOn(global, 'fetch')
    .mockResolvedValue(new Response('', { status: 403 }))
  await expect(installRelease(release, platform, root)).rejects.toThrow(
    'HTTP 403'
  )
})
it('verifies and extracts a matching precompiled release', async () => {
  jest.spyOn(core, 'getInput').mockReturnValue('')
  jest.spyOn(core, 'info').mockImplementation(() => {})
  const name = 'llgo1.0.4.linux-amd64.tar.gz'
  const payload = path.join(root, 'payload')
  fs.mkdirSync(payload)
  fs.mkdirSync(path.join(payload, 'bin'))
  fs.writeFileSync(path.join(payload, 'bin/llgo'), 'compiler')
  const archive = path.join(root, 'fixture.tar.gz')
  execFileSync(archiveTool(), ['-czf', archive, '-C', payload, '.'])
  const checksum = createHash('sha256')
    .update(fs.readFileSync(archive))
    .digest('hex')
  jest.spyOn(global, 'fetch').mockResolvedValue(
    new Response(
      JSON.stringify({
        assets: [
          { name, browser_download_url: 'https://example.invalid/archive' },
          {
            name: 'llgo1.0.4.checksums.txt',
            browser_download_url: 'https://example.invalid/checksums'
          }
        ]
      })
    )
  )
  jest.spyOn(downloads, 'download').mockImplementation(async (url, dest) => {
    if (url.endsWith('checksums'))
      fs.writeFileSync(dest, `${checksum}  ${name}\n`)
    else fs.copyFileSync(archive, dest)
  })
  const dest = path.join(root, 'installed')
  fs.mkdirSync(dest)
  expect(await installRelease(release, platform, dest)).toBe(true)
  expect(fs.readFileSync(path.join(dest, 'bin/llgo'), 'utf8')).toBe('compiler')
})
it('rejects corrupt or unlisted archives', async () => {
  const archive = path.join(root, 'archive')
  fs.writeFileSync(archive, 'bad')
  await expect(
    downloads.verifyChecksum(archive, 'archive', `${'0'.repeat(64)}  archive`)
  ).rejects.toThrow('mismatch')
  await expect(
    downloads.verifyChecksum(archive, 'archive', '')
  ).rejects.toThrow('No SHA-256')
})
