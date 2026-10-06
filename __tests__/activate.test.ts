import childProcess from 'child_process'
import * as core from '@actions/core'
import { installLLGo } from '../src/install'

const platform = process.platform
beforeEach(() => {
  jest.spyOn(core, 'exportVariable').mockImplementation(() => {})
  jest.spyOn(core, 'addPath').mockImplementation(() => {})
  jest.spyOn(core, 'info').mockImplementation(() => {})
  jest.spyOn(core, 'setOutput').mockImplementation(() => {})
})
afterEach(() => {
  jest.restoreAllMocks()
  Object.defineProperty(process, 'platform', { value: platform })
})

it.each(['linux', 'darwin'])(
  'uses the selected LLVM for %s source builds',
  os => {
    Object.defineProperty(process, 'platform', { value: os })
    const exec = jest
      .spyOn(childProcess, 'execFileSync')
      .mockReturnValueOnce('-I/selected/include\n')
      .mockReturnValueOnce('-std=c++17\n')
      .mockReturnValueOnce('-L/selected/lib -lLLVM\n')
      .mockReturnValueOnce('')
      .mockReturnValueOnce('llgo devel\n')
    installLLGo('/compiler checkout', 'source')
    expect(exec).toHaveBeenNthCalledWith(
      4,
      'go',
      ['build', '-tags=byollvm', '-o', 'bin/llgo', './cmd/llgo'],
      expect.objectContaining({
        cwd: '/compiler checkout',
        env: expect.objectContaining({
          LLGO_ROOT: '/compiler checkout',
          CGO_CPPFLAGS: '-I/selected/include',
          CGO_CXXFLAGS: '-std=c++17',
          CGO_LDFLAGS: '-L/selected/lib -lLLVM'
        })
      })
    )
    expect(core.addPath).toHaveBeenCalled()
    expect(core.setOutput).toHaveBeenCalledWith('llgo-version', 'llgo devel')
  }
)

it('keeps the existing Windows build profile', () => {
  Object.defineProperty(process, 'platform', { value: 'win32' })
  const exec = jest
    .spyOn(childProcess, 'execFileSync')
    .mockReturnValueOnce('')
    .mockReturnValueOnce('llgo devel')
  installLLGo('compiler', 'source')
  expect(exec).toHaveBeenNthCalledWith(
    1,
    'go',
    ['build', '-o', 'bin/llgo.exe', './cmd/llgo'],
    expect.any(Object)
  )
  expect(exec).toHaveBeenCalledTimes(2)
})

it('does not require llvm-config when activating a release', () => {
  const exec = jest
    .spyOn(childProcess, 'execFileSync')
    .mockReturnValue('llgo v1.0.6')
  installLLGo('compiler', 'release')
  expect(exec).toHaveBeenCalledTimes(1)
  expect(core.exportVariable).toHaveBeenCalledWith('LLGO_ROOT', 'compiler')
})

it('stops before building when llvm-config fails', () => {
  Object.defineProperty(process, 'platform', { value: 'linux' })
  const exec = jest
    .spyOn(childProcess, 'execFileSync')
    .mockImplementation(() => {
      throw new Error('missing LLVM')
    })
  expect(() => installLLGo('compiler', 'source')).toThrow('missing LLVM')
  expect(exec).toHaveBeenCalledTimes(1)
  expect(core.addPath).not.toHaveBeenCalled()
})

it('explains how to fix a missing llvm-config', () => {
  Object.defineProperty(process, 'platform', { value: 'linux' })
  const exec = jest
    .spyOn(childProcess, 'execFileSync')
    .mockImplementation(() => {
      throw Object.assign(new Error('spawnSync llvm-config ENOENT'), {
        code: 'ENOENT'
      })
    })
  expect(() => installLLGo('compiler', 'source')).toThrow(
    'add the selected LLVM bin directory to PATH'
  )
  expect(exec).toHaveBeenCalledTimes(1)
  expect(core.addPath).not.toHaveBeenCalled()
})

it('requires an installation directory', () => {
  expect(() => installLLGo('', 'source')).toThrow('directory is required')
})
