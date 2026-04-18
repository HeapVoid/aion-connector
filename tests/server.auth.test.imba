import {test, expect, beforeAll, afterAll} from "bun:test"
import {Server} from "../src/server.imba"
import * as tls from "../src/tls.imba"
import {mkdtempSync, rmSync, readFileSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"

# These tests hit a real Server over TLS with a self-signed cert.
# They prove the inbound-bearer field is named aionToken (not
# workspaceToken — spec §2.3 renames the inbound token so
# AION→VPS calls are distinct from VPS→AION).

let srv = null
let url = null
const aionToken = 'a'.repeat(64)
let tmp = null

beforeAll do
	tmp = mkdtempSync(join(tmpdir!, 'aion-srv-'))
	const certPath = join(tmp, 'cert.pem')
	const keyPath = join(tmp, 'key.pem')
	await tls.generateSelfSigned(certPath, keyPath)
	srv = new Server({
		port: 0
		cert: readFileSync(certPath)
		key: readFileSync(keyPath)
		aionToken: aionToken
	})
	srv.route('POST', '/ok', do { status: 200, body: { ok: yes } })
	await srv.start!
	url = "https://127.0.0.1:{srv.srv.address().port}/ok"

afterAll do
	await srv.stop! if srv
	rmSync(tmp, { recursive: yes, force: yes }) if tmp

test "request without Authorization → 403", do
	const res = await fetch(url, { method: 'POST', tls: { rejectUnauthorized: no } })
	expect(res.status).toBe(403)

test "request with wrong bearer → 403", do
	const res = await fetch(url, {
		method: 'POST'
		headers: { authorization: "Bearer wrong" }
		tls: { rejectUnauthorized: no }
	})
	expect(res.status).toBe(403)

test "request with correct aionToken bearer → 200", do
	const res = await fetch(url, {
		method: 'POST'
		headers: { authorization: "Bearer {aionToken}" }
		tls: { rejectUnauthorized: no }
	})
	expect(res.status).toBe(200)
