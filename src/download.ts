import { createHash } from 'crypto'
import fs from 'fs'
import https from 'https'
import { pipeline } from 'stream/promises'
import { downloadTimeout, retryNetwork } from './network'

export async function download(
  url: string,
  destination: string
): Promise<void> {
  await retryNetwork(async () => downloadOnce(url, destination))
}

async function downloadOnce(
  url: string,
  destination: string,
  redirects = 0
): Promise<void> {
  const parsed = new URL(url)
  const trustedHosts = [
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com'
  ]
  if (
    parsed.protocol !== 'https:' ||
    !trustedHosts.includes(parsed.hostname) ||
    parsed.username ||
    parsed.password ||
    redirects > 5
  )
    throw new Error(`Invalid download URL or too many redirects: ${url}`)
  const response = await new Promise<import('http').IncomingMessage>(
    (resolve, reject) => {
      const request = https.get(
        url,
        { headers: { 'User-Agent': 'setup-llgo' } },
        resolve
      )
      request.setTimeout(120000, () => request.destroy(downloadTimeout()))
      request.on('error', reject)
    }
  )
  if (
    response.statusCode &&
    [301, 302, 303, 307, 308].includes(response.statusCode) &&
    response.headers.location
  ) {
    response.resume()
    await downloadOnce(
      new URL(response.headers.location, url).href,
      destination,
      redirects + 1
    )
    return
  }
  if (response.statusCode !== 200) {
    response.resume()
    throw new Error(`Download failed (${response.statusCode}): ${url}`)
  }
  // Keep the inactivity timeout active while the body is streamed as well.
  response.setTimeout(120000, () => response.destroy(downloadTimeout()))
  await pipeline(response, fs.createWriteStream(destination))
}

export async function verifyChecksum(
  archive: string,
  filename: string,
  checksums: string
): Promise<void> {
  const entry = checksums
    .split(/\r?\n/)
    .find(line => line.trim().split(/\s+/)[1]?.replace(/^\*/, '') === filename)
  const expected = entry?.trim().split(/\s+/)[0]
  if (!expected || !/^[a-f\d]{64}$/i.test(expected))
    throw new Error(`No SHA-256 checksum for ${filename}`)
  const hash = createHash('sha256')
  for await (const chunk of fs.createReadStream(archive)) hash.update(chunk)
  if (hash.digest('hex') !== expected.toLowerCase())
    throw new Error(`SHA-256 mismatch for ${filename}`)
}
