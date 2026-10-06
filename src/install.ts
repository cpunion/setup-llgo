import * as core from '@actions/core'
import { execFileSync } from 'child_process'
import fs from 'fs'
import os from 'os'
import path from 'path'
import {
  parseRemoteRefs,
  resolveVersion,
  Selection,
  versionInput,
  verifyInstalledVersion
} from './resolve'
import { platformFor, Platform, releaseAsset, releaseVersion } from './platform'
import { download, verifyChecksum } from './download'
import { retryNetwork } from './network'

const repository = 'https://github.com/xgo-dev/llgo.git'

export function archiveTool(): string {
  // Git for Windows also ships GNU tar, which treats C: as a remote host
  // and cannot unpack ZIPs. Use the native bsdtar explicitly.
  return process.platform === 'win32'
    ? path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'tar.exe')
    : 'tar'
}
function git(args: string[], cwd?: string): string {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0' }
  }).trim()
}

export function checkoutLLGo(
  selected: Selection,
  sourceDir: string,
  repo = repository
): string {
  git(['init', '--quiet'], sourceDir)
  git(['remote', 'add', 'origin', repo], sourceDir)
  let revision = selected.sha
  if (selected.kind === 'commit' && revision.length < 40) {
    // A server cannot fetch arbitrary abbreviated object IDs. Resolve against
    // fetched history, letting Git reject unknown or ambiguous abbreviations.
    git(
      [
        'fetch',
        '--quiet',
        '--filter=blob:none',
        'origin',
        '+refs/heads/*:refs/remotes/origin/*',
        '+refs/tags/*:refs/tags/*'
      ],
      sourceDir
    )
    revision = git(['rev-parse', '--verify', `${revision}^{commit}`], sourceDir)
  } else {
    git(['fetch', '--quiet', '--depth=1', 'origin', revision], sourceDir)
  }
  if (selected.kind === 'tag')
    git(['update-ref', selected.ref, revision], sourceDir)
  git(['checkout', '--quiet', '--detach', revision], sourceDir)
  return git(['rev-parse', 'HEAD'], sourceDir)
}

interface Release {
  assets: { name: string; browser_download_url: string }[]
}
export async function installRelease(
  selected: Selection,
  platform: Platform,
  destination: string
): Promise<boolean> {
  if (selected.kind !== 'tag') return false
  const tag = selected.ref.slice('refs/tags/'.length)
  const headers: Record<string, string> = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'setup-llgo'
  }
  const token = core.getInput('token')
  if (token) headers.Authorization = `Bearer ${token}`
  const release = await retryNetwork(async () => {
    const response = await fetch(
      `https://api.github.com/repos/xgo-dev/llgo/releases/tags/${encodeURIComponent(
        tag
      )}`,
      { headers, signal: AbortSignal.timeout(120000) }
    )
    if (response.status === 404) return undefined
    if (!response.ok)
      throw new Error(`Release lookup failed: HTTP ${response.status}`)
    return (await response.json()) as Release
  })
  if (!release) return false
  const filename = releaseAsset(tag, platform)
  const asset = release.assets.find(item => item.name === filename)
  if (!asset) return false
  const checksumAsset = release.assets.find(
    item => item.name === `llgo${releaseVersion(tag)}.checksums.txt`
  )
  if (!checksumAsset)
    throw new Error(`Release ${tag} is missing its checksum manifest`)
  const archive = path.join(destination, filename)
  const checksums = path.join(destination, 'checksums.txt')
  await download(checksumAsset.browser_download_url, checksums)
  await download(asset.browser_download_url, archive)
  await verifyChecksum(archive, filename, fs.readFileSync(checksums, 'utf8'))
  execFileSync(archiveTool(), ['-xf', archive, '-C', destination], {
    stdio: 'inherit'
  })
  fs.unlinkSync(archive)
  fs.unlinkSync(checksums)
  core.info(`Installed release asset ${filename}`)
  return true
}

export interface Installation {
  directory: string
  method: string
  ref: string
  revision: string
}

export async function prepareLLGo(): Promise<Installation> {
  const platform = platformFor(
    process.platform,
    core.getInput('architecture') || process.env.RUNNER_ARCH || process.arch,
    core.getInput('windows-abi') || 'msvc'
  )
  const method = core.getInput('install-method') || 'auto'
  if (!['auto', 'source', 'release'].includes(method))
    throw new Error(`Unknown install-method: ${method}`)
  const refs = parseRemoteRefs(
    git(['ls-remote', '--heads', '--tags', repository])
  )
  const selected = resolveVersion(
    versionInput(
      core.getInput('llgo-version'),
      core.getInput('llgo-version-file')
    ),
    refs
  )
  // Own only a unique temporary directory; never touch the user's ~/workdir.
  const sourceDir = fs.mkdtempSync(
    path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'setup-llgo-')
  )
  try {
    const prebuilt =
      method !== 'source' &&
      (await installRelease(selected, platform, sourceDir))
    if (!prebuilt && method === 'release')
      throw new Error(
        `No release asset for ${selected.ref} on ${platform.os}/${platform.arch}/${platform.abi}`
      )
    const revision = prebuilt ? selected.sha : checkoutLLGo(selected, sourceDir)
    core.info(
      `Selected ${selected.ref} at ${revision} (${
        prebuilt ? 'release' : 'source'
      })`
    )
    core.setOutput('install-dir', sourceDir)
    core.setOutput('install-method', prebuilt ? 'release' : 'source')
    core.setOutput('llgo-revision', revision)
    core.setOutput('llgo-ref', selected.ref)
    core.setOutput('llgo-version-verified', selected.kind === 'tag')
    core.setOutput('architecture', platform.arch)
    core.exportVariable(
      'SETUP_LLGO_ACTION_PATH',
      process.env.GITHUB_ACTION_PATH || ''
    )
    return {
      directory: sourceDir,
      method: prebuilt ? 'release' : 'source',
      ref: selected.ref,
      revision
    }
  } catch (error) {
    fs.rmSync(sourceDir, { recursive: true, force: true })
    throw error
  }
}

export function installLLGo(sourceDir: string, method: string): void {
  if (!sourceDir) throw new Error('The LLGo installation directory is required')
  const env = { ...process.env, LLGO_ROOT: sourceDir }
  const executable = process.platform === 'win32' ? 'llgo.exe' : 'llgo'
  if (method === 'source') {
    const args = ['build']
    if (process.platform !== 'win32') {
      // Use the selected LLVM, not the Go binding's default major version.
      // Keep these flags scoped to building the compiler itself.
      const flags = (...options: string[]): string =>
        execFileSync('llvm-config', options, { encoding: 'utf8' }).trim()
      Object.assign(env, {
        CGO_CPPFLAGS: flags('--cflags'),
        CGO_CXXFLAGS: flags('--cxxflags'),
        CGO_LDFLAGS: flags('--ldflags', '--libs', '--system-libs')
      })
      args.push('-tags=byollvm')
    }
    args.push('-o', `bin/${executable}`, './cmd/llgo')
    execFileSync('go', args, {
      cwd: sourceDir,
      env,
      stdio: 'inherit'
    })
  }
  const binary = path.join(sourceDir, 'bin', executable)
  const version = execFileSync(binary, ['version'], {
    env,
    encoding: 'utf8'
  }).trim()
  if (method === 'release')
    verifyInstalledVersion(version, process.env.SETUP_LLGO_REF || '')
  core.exportVariable('LLGO_ROOT', sourceDir)
  core.addPath(path.dirname(binary))
  core.info(version)
  core.setOutput('llgo-version', version)
}
