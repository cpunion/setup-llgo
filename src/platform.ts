export interface Platform {
  os: string
  arch: string
  abi: string
}

export function platformFor(
  os: string,
  architecture: string,
  abi: string
): Platform {
  const arch =
    (
      { x64: 'amd64', x86_64: 'amd64', aarch64: 'arm64' } as Record<
        string,
        string
      >
    )[architecture.toLowerCase()] || architecture.toLowerCase()
  if (!['linux', 'darwin', 'win32'].includes(os))
    throw new Error(`Unsupported OS: ${os}`)
  if (!['amd64', 'arm64'].includes(arch))
    throw new Error(`Unsupported architecture: ${architecture}`)
  if (os === 'win32' && !['msvc', 'mingw'].includes(abi))
    throw new Error(`Unsupported Windows ABI: ${abi}`)
  return {
    os: os === 'win32' ? 'windows' : os,
    arch,
    abi: os === 'win32' ? abi : ''
  }
}

export function releaseAsset(tag: string, platform: Platform): string {
  const suffix = platform.os === 'windows' ? `-${platform.abi}.zip` : '.tar.gz'
  return `llgo${tag.replace(/^v/, '')}.${platform.os}-${platform.arch}${suffix}`
}
