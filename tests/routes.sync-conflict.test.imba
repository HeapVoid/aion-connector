import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync, readFileSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"
import {registerRoutes} from "../src/routes.imba"
import {StubAdapter} from "../src/adapter.imba"
import {personaPath} from "../src/sync.imba"
import {sha256Hex} from "../src/utils.imba"

const _fetch = globalThis.fetch.bind(globalThis)

let server = null
let port = 0
let home = null
const token = 'tok'

beforeEach do
	home = mkdtempSync(join(tmpdir!, 'aion-conf-home-'))
	const certP = join(home, 'cert.pem')
	const keyP = join(home, 'key.pem')
	await generateSelfSigned(certP, keyP)
	const { cert, key } = loadCertKey(certP, keyP)
	port = 19800 + Math.floor(Math.random! * 200)
	server = new Server({ port, cert, key, workspaceToken: token })
	const adapter = new StubAdapter(home)
	await adapter.configure({ persona: 'v1', skills: [], model: 'm', credentials: null })
	registerRoutes(server, { adapter })
	await server.start!

afterEach do
	await server.stop!

def post path, body
	_fetch "https://127.0.0.1:{port}{path}",
		method: 'POST'
		headers: { 'content-type': 'application/json', 'authorization': "Bearer {token}" }
		body: JSON.stringify(body or {})
		tls: { rejectUnauthorized: false }

test "sync/persona returns 409 on stale expected_prev_hash", do
	const res = await post('/coordinator/sync/persona', { content: 'v2', expected_prev_hash: sha256Hex('stale') })
	expect(res.status).toBe(409)
	const b = await res.json!
	expect(b.actualHash).toBe(sha256Hex('v1'))
	expect(readFileSync(personaPath(home), 'utf8')).toBe('v1')

test "sync/persona with current hash succeeds", do
	const correct = sha256Hex('v1')
	const res = await post('/coordinator/sync/persona', { content: 'v2', expected_prev_hash: correct })
	expect(res.status).toBe(200)
	expect(readFileSync(personaPath(home), 'utf8')).toBe('v2')
