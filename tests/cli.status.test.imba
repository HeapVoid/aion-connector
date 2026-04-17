import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {exec} from "../src/utils.imba"
import {writeState} from "../src/state.imba"

let oldHome = null
let sandbox = null
beforeEach do
	sandbox = mkdtempSync(join(tmpdir!, 'aion-cli-'))
	oldHome = process.env.HOME
	process.env.HOME = sandbox
	writeState({
		workspace_id: 'abc-123'
		workspace_token: 'x'
		aion_url: 'https://aion.test'
		port: 7777
		cert_fingerprint: 'f'.repeat(64)
		coordinator: { program: 'stub', model: 'm', auth_mode: 'api_key' }
	}, sandbox)

afterEach do
	process.env.HOME = oldHome

test "status prints workspace_id + port", 30000, do
	const build = await exec(['bun', 'run', 'build'])
	if build.exitCode != 0
		throw new Error("build failed: {build.stderr}")
	const r = await exec(['node', 'dist/cli.js', 'status'], { env: process.env })
	expect(r.stdout).toContain('abc-123')
	expect(r.stdout).toContain('7777')
