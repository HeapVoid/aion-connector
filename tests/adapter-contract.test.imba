import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {StubAdapter, makeAdapter} from "../src/adapter.imba"

let home = null
beforeEach do
	home = mkdtempSync(join(tmpdir!, 'aion-adapter-'))

test "StubAdapter starts in ready state", do
	const a = new StubAdapter(home)
	const h = await a.health!
	expect(h.state).toBe('ready')

test "StubAdapter configure writes persona + skills", do
	const a = new StubAdapter(home)
	await a.configure({ persona: 'be helpful', skills: [{ name: 'k1', content: 'c1' }] })
	const out = await a.readSkills!
	expect(out.persona.content).toBe('be helpful')
	expect(out.skills.length).toBe(1)
	expect(out.skills[0].name).toBe('k1')

test "writeSkills returns persona + per-skill hashes", do
	const a = new StubAdapter(home)
	const r = await a.writeSkills({ persona: 'p', skills: [{ name: 's', content: 'body' }] })
	expect(typeof r.persona).toBe('string')
	expect(r.skills.length).toBe(1)
	expect(r.skills[0].name).toBe('s')

test "StubAdapter startAuth returns null (api-key only)", do
	const a = new StubAdapter(home)
	expect(await a.startAuth!).toBe(null)

test "makeAdapter('stub') returns a StubAdapter", do
	const a = makeAdapter('stub', home)
	expect(a instanceof StubAdapter).toBe(true)

test "makeAdapter of unknown program throws", do
	let threw = no
	try
		makeAdapter('bogus', home)
	catch e
		threw = yes
	expect(threw).toBe(true)
