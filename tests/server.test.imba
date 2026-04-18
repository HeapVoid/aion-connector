import {test, expect, beforeEach, afterEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, loadCertKey} from "../src/tls.imba"
import {Server} from "../src/server.imba"

let server = null
let port = 0
const token = 'test-token-abc'

beforeEach do
	const dir = mkdtempSync(join(tmpdir!, 'aion-srv-'))
	const certPath = join(dir, 'cert.pem')
	const keyPath = join(dir, 'key.pem')
	await generateSelfSigned(certPath, keyPath)
	const ck = loadCertKey(certPath, keyPath)
	port = 19100 + Math.floor(Math.random! * 500)
	server = new Server({ port: port, cert: ck.cert, key: ck.key, aionToken: token })
	await server.start!

afterEach do
	await server.stop!

const _fetch = globalThis.fetch.bind(globalThis)

def postJson path, body = {}, authToken = token
	_fetch("https://127.0.0.1:{port}{path}", {
		method: 'POST'
		headers: { 'content-type': 'application/json', 'authorization': "Bearer {authToken}" }
		body: JSON.stringify(body)
		tls: { rejectUnauthorized: false }
	})

test "ping returns ok with VERSION", do
	const res = await postJson('/ping', {})
	expect(res.status).toBe(200)
	const body = await res.json!
	expect(body.ok).toBe(true)
	expect(body.v).toBeGreaterThan(0)

test "wrong bearer token returns 403", do
	const res = await postJson('/ping', {}, 'wrong')
	expect(res.status).toBe(403)

test "registered route receives params and body", do
	let seen = null
	server.route('POST', '/foo/:id', do(params, body)
		seen = { params: params, body: body }
		{ status: 200, body: { ok: yes, id: params.id } })
	const res = await postJson('/foo/abc123', { hello: 'world' })
	expect(res.status).toBe(200)
	expect(seen.params.id).toBe('abc123')
	expect(seen.body.hello).toBe('world')

test "unknown route returns 404", do
	const res = await postJson('/nope', {})
	expect(res.status).toBe(404)
