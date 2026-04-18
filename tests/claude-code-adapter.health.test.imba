import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, rmSync, mkdirSync, writeFileSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"
import {ClaudeCodeAdapter} from "../src/claude-code-adapter.imba"

# These tests drive the adapter's health() logic directly. They
# manipulate a temp HOME directory (no real user creds touched)
# and flip the `installed` bit so they don't invoke `which claude`
# on every probe. The first test specifically exercises the which
# fallback by pointing PATH at an empty directory.

let home = null

beforeEach(do
	home = mkdtempSync(join(tmpdir!, 'aion-test-'))
	mkdirSync(join(home, '.claude'), { recursive: yes })
)

afterEach(do
	rmSync(home, { recursive: yes, force: yes })
)

test "health returns claude_missing when binary absent", do
	# Force PATH to a dir that has no `claude` so `which` fails.
	const origPath = process.env.PATH
	process.env.PATH = '/nonexistent'
	const a = new ClaudeCodeAdapter(home)
	const h = await a.health()
	process.env.PATH = origPath
	expect(h.state).toBe('error')
	expect(h.detail).toBe('claude_missing')

test "health returns not_authorized when credentials.json absent", do
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes   # skip the which probe
	const h = await a.health()
	expect(h.state).toBe('error')
	expect(h.detail).toBe('not_authorized')

test "health returns not_authorized when credentials.json says expired", do
	const creds = { expires_at: Date.now() - 1000 }
	writeFileSync(join(home, '.claude/credentials.json'), JSON.stringify(creds))
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('error')
	expect(h.detail).toBe('not_authorized')

test "health returns ready when credentials.json present and fresh", do
	const creds = { expires_at: Date.now() + 3600 * 1000 }
	writeFileSync(join(home, '.claude/credentials.json'), JSON.stringify(creds))
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('ready')

test "health returns creds_corrupt on unparseable credentials.json", do
	writeFileSync(join(home, '.claude/credentials.json'), '{not json')
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('error')
	expect(h.detail).toBe('creds_corrupt')

test "health treats credentials.json without expires_at as ready (adapter can't know)", do
	writeFileSync(join(home, '.claude/credentials.json'), '{}')
	const a = new ClaudeCodeAdapter(home)
	a.installed = yes
	const h = await a.health()
	expect(h.state).toBe('ready')
