import {test, expect} from "bun:test"
import {sha256Hex, exec} from "../src/utils.imba"

test "sha256Hex returns 64 lowercase hex chars", do
	const h = sha256Hex("hello")
	expect(h.length).toBe(64)
	expect(h).toMatch(/^[0-9a-f]+$/)
	expect(h).toBe("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

test "exec captures stdout and exitCode", do
	const r = await exec(["echo", "hi"])
	expect(r.exitCode).toBe(0)
	expect(r.stdout.trim!).toBe("hi")
