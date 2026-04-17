import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, statSync, existsSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {generateSelfSigned, fingerprint, loadCertKey} from "../src/tls.imba"

let dir = null
beforeEach do
	dir = mkdtempSync(join(tmpdir!, 'aion-tls-'))

test "generateSelfSigned creates cert+key with mode 600 and returns 64-hex fingerprint", do
	const cert = join(dir, 'cert.pem')
	const key = join(dir, 'key.pem')
	const fp = await generateSelfSigned(cert, key)
	expect(existsSync(cert)).toBe(true)
	expect(existsSync(key)).toBe(true)
	expect(statSync(cert).mode & 0o777).toBe(0o600)
	expect(statSync(key).mode & 0o777).toBe(0o600)
	expect(fp.length).toBe(64)
	expect(fp).toMatch(/^[0-9a-f]+$/)

test "fingerprint is deterministic for a given cert", do
	const cert = join(dir, 'cert.pem')
	const key = join(dir, 'key.pem')
	const fp1 = await generateSelfSigned(cert, key)
	const fp2 = await fingerprint(cert)
	expect(fp2).toBe(fp1)

test "loadCertKey returns buffers", do
	const cert = join(dir, 'cert.pem')
	const key = join(dir, 'key.pem')
	await generateSelfSigned(cert, key)
	const { cert: c, key: k } = loadCertKey(cert, key)
	expect(c.length).toBeGreaterThan(0)
	expect(k.length).toBeGreaterThan(0)
