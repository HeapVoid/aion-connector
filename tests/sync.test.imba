import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, existsSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {readFile, writeFile, listSkills, writeSkills, personaPath, skillPath, ConflictError, hashFile} from "../src/sync.imba"
import {sha256Hex} from "../src/utils.imba"

let home = null
beforeEach do
	home = mkdtempSync(join(tmpdir!, 'aion-sync-'))

test "writeFile with no prev hash writes and returns hash", do
	const h = writeFile(personaPath(home), 'hello')
	expect(h).toBe(sha256Hex('hello'))
	expect(readFile(personaPath(home)).content).toBe('hello')

test "writeFile with matching prev hash overwrites", do
	writeFile(personaPath(home), 'v1')
	const prev = hashFile(personaPath(home))
	const next = writeFile(personaPath(home), 'v2', prev)
	expect(readFile(personaPath(home)).content).toBe('v2')
	expect(next).toBe(sha256Hex('v2'))

test "writeFile with wrong prev hash throws ConflictError", do
	writeFile(personaPath(home), 'v1')
	let thrown = null
	try
		writeFile(personaPath(home), 'v2', 'wronghash')
	catch e
		thrown = e
	expect(thrown instanceof ConflictError).toBe(true)
	expect(thrown.actualHash).toBe(sha256Hex('v1'))
	expect(readFile(personaPath(home)).content).toBe('v1')

test "listSkills returns names+hashes+content", do
	writeFile(skillPath(home, 'deploy'), 'body A')
	writeFile(skillPath(home, 'debug'), 'body B')
	const list = listSkills(home).sort(do(a,b) a.name.localeCompare(b.name))
	expect(list.length).toBe(2)
	expect(list[0].name).toBe('debug')
	expect(list[0].hash).toBe(sha256Hex('body B'))

test "writeSkills replaces directory contents", do
	writeFile(skillPath(home, 'old'), 'x')
	writeSkills(home, [{ name: 'new', content: 'y' }])
	const list = listSkills(home)
	expect(list.length).toBe(1)
	expect(list[0].name).toBe('new')
	expect(existsSync(skillPath(home, 'old'))).toBe(false)
