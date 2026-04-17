import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, existsSync, readFileSync, statSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {ClaudeCodeAdapter} from "../src/claude-code-adapter.imba"
import {personaPath, skillPath} from "../src/sync.imba"

const SKIP = process.env.CLAUDE_CODE_INSTALLED != '1'

let home = null
beforeEach do
	home = mkdtempSync(join(tmpdir!, 'aion-cc-'))

test "configure writes persona.md + skills/*", do
	const a = new ClaudeCodeAdapter(home)
	await a.configure({ persona: 'be terse', skills: [{ name: 'deploy', content: 'steps' }], model: 'sonnet-4.6', credentials: { api_key: 'sk-xxx' } })
	expect(readFileSync(personaPath(home), 'utf8')).toBe('be terse')
	expect(readFileSync(skillPath(home, 'deploy'), 'utf8')).toBe('steps')
	const envPath = join(home, 'coordinator', 'credentials.env')
	expect(existsSync(envPath)).toBe(true)
	expect(statSync(envPath).mode & 0o777).toBe(0o600)
	expect(readFileSync(envPath, 'utf8')).toContain('sk-xxx')

const runOrSkip = SKIP ? test.skip : test
runOrSkip "health returns ready when binary is present", do
	const a = new ClaudeCodeAdapter(home)
	await a.installCoordinator({ program: 'claude-code' })
	const h = await a.health!
	expect(h.state).toBe('ready')

const runOrSkipAuth = SKIP ? test.skip : test
runOrSkipAuth "startAuth surfaces an auth URL", 20000, do
	const a = new ClaudeCodeAdapter(home)
	const r = await a.startAuth!
	expect(r.url).toMatch(/^https?:/)
	a.authProc..kill!
