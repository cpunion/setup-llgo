import * as semver from 'semver'
import fs from 'fs'
import path from 'path'

export interface RemoteRef {
  name: string
  sha: string
  kind: 'tag' | 'branch'
}
export interface Selection {
  ref: string
  sha: string
  kind: 'tag' | 'branch' | 'commit'
}

export function parseRemoteRefs(output: string): RemoteRef[] {
  const refs = new Map<string, RemoteRef>()
  const peeled = new Map<string, string>()
  for (const line of output.split('\n')) {
    const [sha, ref] = line.trim().split(/\s+/)
    if (!sha || !ref) continue
    if (ref.endsWith('^{}')) peeled.set(ref.slice(0, -3), sha)
    else if (ref.startsWith('refs/tags/'))
      refs.set(ref, { name: ref.slice(10), sha, kind: 'tag' })
    else if (ref.startsWith('refs/heads/'))
      refs.set(ref, { name: ref.slice(11), sha, kind: 'branch' })
  }
  for (const [ref, sha] of peeled) {
    const tag = refs.get(ref)
    if (tag) tag.sha = sha
  }
  return [...refs.values()]
}

function selected(ref: RemoteRef): Selection {
  return {
    ref: `refs/${ref.kind === 'tag' ? 'tags' : 'heads'}/${ref.name}`,
    sha: ref.sha,
    kind: ref.kind
  }
}
function glob(pattern: string, name: string): boolean {
  const escaped = pattern.replace(/[|\\{}()[\]^$+?.*]/g, char => {
    if (char === '*') return '.*'
    if (char === '?') return '.'
    return `\\${char}`
  })
  return new RegExp(`^${escaped}$`).test(name)
}

export function resolveVersion(input: string, refs: RemoteRef[]): Selection {
  const spec = input.trim() || 'latest'
  const tags = refs.filter(ref => ref.kind === 'tag')
  const branches = refs.filter(ref => ref.kind === 'branch')
  if (spec.startsWith('refs/')) {
    const exact = refs.find(ref => selected(ref).ref === spec)
    if (!exact) throw new Error(`Unknown LLGo ref: ${spec}`)
    return selected(exact)
  }
  const exactTag = tags.find(
    ref => ref.name === spec || ref.name === `v${spec}`
  )
  if (exactTag) return selected(exactTag)
  const exactBranch = branches.find(ref => ref.name === spec)
  if (exactBranch) return selected(exactBranch)
  if (/^[a-f\d]{7,40}$/i.test(spec))
    return { kind: 'commit', ref: spec, sha: spec.toLowerCase() }
  const range = semver.validRange(spec === 'latest' ? '*' : spec)
  const matches =
    range !== null
      ? tags.filter(
          ref => semver.valid(ref.name) && semver.satisfies(ref.name, range)
        )
      : tags.filter(ref => glob(spec, ref.name))
  const versions = matches.filter(ref => semver.valid(ref.name))
  versions.sort((a, b) => semver.rcompare(a.name, b.name))
  if (versions.length) return selected(versions[0])
  if (matches.length === 1) return selected(matches[0])
  if (matches.length > 1) throw new Error(`Ambiguous LLGo tag pattern: ${spec}`)
  const branchMatches = branches.filter(ref => glob(spec, ref.name))
  if (branchMatches.length === 1) return selected(branchMatches[0])
  if (branchMatches.length > 1)
    throw new Error(`Ambiguous LLGo branch pattern: ${spec}`)
  throw new Error(`No LLGo version, tag, branch or commit matches: ${spec}`)
}

export function versionInput(explicit: string, file: string): string {
  if (explicit.trim()) return explicit.trim()
  if (!file) return ''
  const contents = fs.readFileSync(file, 'utf8').trim()
  if (['go.mod', 'go.work'].includes(path.basename(file))) {
    const match = contents.match(/^\s*\/\/\s*llgo\s+(.+?)\s*$/m)
    if (!match) throw new Error(`No // llgo version directive in ${file}`)
    return match[1]
  }
  if (!contents) throw new Error(`Empty LLGo version file: ${file}`)
  return contents
}

export function verifyInstalledVersion(actual: string, ref: string): void {
  if (!ref.startsWith('refs/tags/')) return
  const expected = semver.valid(ref.slice('refs/tags/'.length))
  if (!expected) return
  const reported = actual.match(/^llgo v?(\S+)\s/)
  if (!reported || reported[1] !== expected)
    throw new Error(`Installed LLGo version ${actual} does not match ${ref}`)
}
