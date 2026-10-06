import * as core from '@actions/core'
import fs from 'fs'
import { installLLGo, prepareLLGo } from './install'

async function run(): Promise<void> {
  try {
    if (process.env.SETUP_LLGO_PHASE === 'prepare') {
      const installation = await prepareLLGo()
      if (process.env.SETUP_LLGO_RESULT)
        fs.writeFileSync(
          process.env.SETUP_LLGO_RESULT,
          JSON.stringify(installation)
        )
    } else if (process.env.SETUP_LLGO_PHASE === 'install')
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
