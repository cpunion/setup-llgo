import * as core from '@actions/core'
import { EventEmitter } from 'events'
import fs from 'fs'
import type { ClientRequest, IncomingMessage } from 'http'
import https from 'https'
import os from 'os'
import path from 'path'
import { Readable } from 'stream'
import { download } from '../src/download'
import { downloadTimeout, retryNetwork } from '../src/network'

beforeEach(() => {
  jest.useFakeTimers()
  jest.spyOn(core, 'info').mockImplementation(() => {})
})
afterEach(() => {
  jest.restoreAllMocks()
  jest.useRealTimers()
})

it('retries wrapped fetch transport failures with bounded backoff', async () => {
  const error = new TypeError('fetch failed', {
    cause: Object.assign(new Error('reset'), { code: 'ECONNRESET' })
  })
  const operation = jest
    .fn()
    .mockRejectedValueOnce(error)
    .mockResolvedValue('ok')
  const result = retryNetwork(operation)
  await jest.advanceTimersByTimeAsync(999)
  expect(operation).toHaveBeenCalledTimes(1)
  await jest.advanceTimersByTimeAsync(1)
  expect(await result).toBe('ok')
  expect(operation).toHaveBeenCalledTimes(2)
})

it('stops after three failed transfers and uses 1s/2s delays', async () => {
  const operation = jest.fn().mockRejectedValue(downloadTimeout())
  const result = (async () => {
    try {
      return await retryNetwork(operation)
    } catch (error) {
      return error
    }
  })()
  await jest.advanceTimersByTimeAsync(1000)
  expect(operation).toHaveBeenCalledTimes(2)
  await jest.advanceTimersByTimeAsync(1999)
  expect(operation).toHaveBeenCalledTimes(2)
  await jest.advanceTimersByTimeAsync(1)
  await expect(result).resolves.toMatchObject({ message: 'Download timed out' })
  expect(operation).toHaveBeenCalledTimes(3)
})

it.each([
  new Error('HTTP 404'),
  new Error('HTTP 403'),
  new Error('SHA-256 mismatch'),
  Object.assign(new Error('disk full'), { code: 'ENOSPC' })
])('does not retry permanent errors: %s', async error => {
  const operation = jest.fn().mockRejectedValue(error)
  await expect(retryNetwork(operation)).rejects.toBe(error)
  expect(operation).toHaveBeenCalledTimes(1)
})

it('restarts an archive download after a connection reset', async () => {
  // Use real stream scheduling; the one-second retry also exercises the actual
  // wrapper used by downloads rather than only the retry helper.
  jest.useRealTimers()
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'llgo-download-test-'))
  try {
    const destination = path.join(root, 'archive')
    fs.writeFileSync(destination, 'previous partial archive')
    const get = jest.spyOn(https, 'get')
    get.mockImplementation((_url, _options, callback) => {
      const stream =
        get.mock.calls.length === 1
          ? Readable.from(
              (async function* () {
                yield 'partial transfer'
                throw Object.assign(new Error('reset'), { code: 'ECONNRESET' })
              })()
            )
          : Readable.from(['complete archive'])
      const response = Object.assign(stream, {
        statusCode: 200,
        headers: {},
        setTimeout: jest.fn()
      }) as unknown as IncomingMessage
      const request = Object.assign(new EventEmitter(), {
        setTimeout: jest.fn()
      }) as unknown as ClientRequest
      process.nextTick(() => callback?.(response))
      return request
    })
    await download('https://github.com/example/archive', destination)
    expect(get).toHaveBeenCalledTimes(2)
    expect(fs.readFileSync(destination, 'utf8')).toBe('complete archive')
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
