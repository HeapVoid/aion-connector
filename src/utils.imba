import {spawn} from 'child_process'
import {createHash} from 'crypto'
import {chmodSync} from 'fs'

export def log ...args
	console.log("[aion-connector]", ...args)

export def error ...args
	console.error("[aion-connector]", ...args)

# Spawn, collect stdout/stderr, return {stdout, stderr, exitCode}
export def exec args, opts = {}
	new Promise do(ok, fail)
		const proc = spawn(args[0], args.slice(1), { ...opts, stdio: ['pipe', 'pipe', 'pipe'] })
		let stdout = ''
		let stderr = ''
		proc.stdout.on('data', do(chunk) stdout += chunk.toString!)
		proc.stderr.on('data', do(chunk) stderr += chunk.toString!)
		proc.on('error', do(err) fail(err))
		proc.on('close', do(code)
			ok({ stdout, stderr, exitCode: code })
		)

export def sha256Hex buf
	createHash('sha256').update(buf).digest('hex')

export def ensureMode path, mode
	chmodSync(path, mode)
