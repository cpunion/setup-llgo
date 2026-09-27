import * as core from '@actions/core'

function isTransientNetworkError(error: unknown): boolean {
  for (let depth = 0; error instanceof Error && depth < 3; depth++) {
    if (
      error.name === 'TimeoutError' ||
      [
        'ECONNRESET',
        'ECONNREFUSED',
        'ETIMEDOUT',
        'EAI_AGAIN',
        'ENOTFOUND',
        'ENETUNREACH',
        'EHOSTUNREACH',
        'ERR_STREAM_PREMATURE_CLOSE',
        'UND_ERR_SOCKET',
        'UND_ERR_CONNECT_TIMEOUT',
        'UND_ERR_HEADERS_TIMEOUT',
        'UND_ERR_BODY_TIMEOUT'
      ].includes((error as Error & { code?: string }).code || '')
    )
      return true
    error = error.cause
  }
  return false
}

export async function retryNetwork<T>(operation: () => Promise<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await operation()
    } catch (error) {
      // HTTP responses, bad checksums and filesystem errors are not transient
      // transport failures. In particular, never retry a missing release.
      if (attempt === 2 || !isTransientNetworkError(error)) throw error
      core.info(`Network transfer failed; retrying (attempt ${attempt + 2}/3)`)
      await new Promise(resolve => setTimeout(resolve, 1000 * 2 ** attempt))
    }
  }
}

export function downloadTimeout(): Error {
  return Object.assign(new Error('Download timed out'), { code: 'ETIMEDOUT' })
}
