import {test, expect} from "bun:test"
import {createServer} from 'net'
import {pickFreePort} from "../src/port.imba"

test "returns a port in the requested range", do
	const p = await pickFreePort(18000, 18010)
	expect(p).toBeGreaterThanOrEqual(18000)
	expect(p).toBeLessThanOrEqual(18010)

test "skips ports that are already bound", do
	const blocker = createServer!
	await new Promise do(ok) blocker.listen(18020, '0.0.0.0', ok)
	try
		const p = await pickFreePort(18020, 18022)
		expect(p).not.toBe(18020)
		expect(p).toBeLessThanOrEqual(18022)
	finally
		await new Promise do(ok) blocker.close(ok)

test "throws when no port is free", do
	const a = createServer!
	const b = createServer!
	await new Promise do(ok) a.listen(18030, '0.0.0.0', ok)
	await new Promise do(ok) b.listen(18031, '0.0.0.0', ok)
	try
		let threw = no
		try
			await pickFreePort(18030, 18031)
		catch e
			threw = yes
		expect(threw).toBe(true)
	finally
		await new Promise do(ok) a.close(ok)
		await new Promise do(ok) b.close(ok)
