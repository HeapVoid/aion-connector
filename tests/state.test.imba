import {test, expect, beforeEach} from "bun:test"
import {mkdtempSync, statSync} from 'fs'
import {tmpdir} from 'os'
import {join} from 'path'
import {writeState, readState, mergeState, statePath, ensureDirs} from "../src/state.imba"

let base = null
beforeEach do
	base = mkdtempSync(join(tmpdir!, 'aion-state-'))

test "writeState/readState roundtrip", do
	writeState({ workspace_id: 'abc', port: 7700 }, base)
	const r = readState(base)
	expect(r.workspace_id).toBe('abc')
	expect(r.port).toBe(7700)

test "state file is mode 600", do
	writeState({ x: 1 }, base)
	const st = statSync(statePath(base))
	expect(st.mode & 0o777).toBe(0o600)

test "mergeState preserves existing keys", do
	writeState({ a: 1, b: 2 }, base)
	const r = mergeState({ b: 3, c: 4 }, base)
	expect(r).toEqual({ a: 1, b: 3, c: 4 })

test "readState returns null when missing", do
	expect(readState(base)).toBe(null)

test "ensureDirs creates stateDir mode 700", do
	ensureDirs(base)
	const st = statSync(join(base, '.config', 'aion-connector'))
	expect(st.mode & 0o777).toBe(0o700)
