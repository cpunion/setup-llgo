import * as core from '@actions/core'
import { installLLGo, prepareLLGo } from './install'

async function run(): Promise<void> {
  try {
    if (process.env.SETUP_LLGO_PHASE === 'prepare') await prepareLLGo()
    else if (process.env.SETUP_LLGO_PHASE === 'install')
      installLLGo(
        process.env.SETUP_LLGO_SOURCE || '',
        process.env.SETUP_LLGO_METHOD || ''
      )
    else throw new Error('Unknown setup-llgo phase')
  } catch (error) {
    core.setFailed(error instanceof Error ? error.message : String(error))
  }
}
void run()
