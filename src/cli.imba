import {readFileSync, existsSync, rmSync, unlinkSync} from 'fs'
import {join} from 'path'
import {homedir} from 'os'
import {spawn} from 'child_process'
import {log, error, exec} from './utils.imba'
import * as stateMod from './state.imba'
import * as tls from './tls.imba'
import * as portMod from './port.imba'
import {AionClient} from './aion-client.imba'
import {makeAdapter} from './adapter.imba'
import {Connector, CONNECTOR_VERSION} from './connector.imba'

const _fetch = globalThis.fetch.bind(globalThis)

def parseFlags argv
	const out = {}
	let i = 0
	while i < argv.length
		const a = argv[i]
		if a.startsWith('--')
			const key = a.slice(2)
			const next = argv[i + 1]
			if next !== undefined and !next.startsWith('--')
				out[key] = next
				i = i + 2
			else
				out[key] = 'true'
				i = i + 1
		else
			i = i + 1
	out

def usage
	console.error("Usage: aion-connector <command> [flags]")
	console.error("")
	console.error("Commands:")
	console.error("  run                 Start the connector service (used by systemd)")
	console.error("  install --token X --aion URL --program P --model M --auth-mode api_key|oauth")
	console.error("                      [--workspace-id ID] [--port N] [--persona FILE] [--skills-json FILE]")
	console.error("                      [--api-key VALUE] [--external-ip IP]")
	console.error("  status | logs | restart | stop | doctor | uninstall")
	process.exit(2)

def cmdRun
	const state = stateMod.readState()
	unless state
		error("no workspace state found — run `aion-connector install` first")
		process.exit(1)
	const c = new Connector(state)
	await c.start()
	const shutdown = do
		log("shutting down...")
		await c.stop()
		process.exit(0)
	process.on('SIGTERM', shutdown)
	process.on('SIGINT', shutdown)
	process.on('SIGHUP', do
		log("SIGHUP — restarting coordinator")
		c.adapter..restart()
	)

def cmdInstall f
	const required = ['token', 'aion', 'program', 'model', 'auth-mode']
	let ri = 0
	while ri < required.length
		const k = required[ri]
		unless f[k]
			error("--{k} is required")
			process.exit(2)
		ri = ri + 1
	stateMod.ensureDirs()
	log("generating TLS cert...")
	const fp = await tls.generateSelfSigned(stateMod.certPath(), stateMod.keyPath())
	let port = null
	if f.port
		port = parseInt(f.port)
	else
		port = await portMod.pickFreePort()
	log("chose port {port}, fingerprint {fp}")

	let persona = ''
	if f.persona and existsSync(f.persona)
		persona = readFileSync(f.persona, 'utf8')
	let skills = []
	if f['skills-json'] and existsSync(f['skills-json'])
		skills = JSON.parse(readFileSync(f['skills-json'], 'utf8'))

	log("configuring coordinator ({f.program}, {f.model})...")
	const home = process.env.HOME or homedir()
	const adapter = makeAdapter(f.program, home)
	await adapter.installCoordinator({ program: f.program })
	let creds = null
	if f['auth-mode'] === 'api_key'
		creds = { api_key: f['api-key'] or '' }
	await adapter.configure({
		model: f.model
		credentials: creds
		persona: persona
		skills: skills
	})
	await adapter.start()
	const health = await adapter.health()

	log("registering with AION...")
	const cli = new AionClient(f.aion)
	const reg = await cli.register({
		enrollment_token: f.token
		external_ip: f['external-ip'] or process.env.AION_EXTERNAL_IP or '0.0.0.0'
		port: port
		cert_fingerprint: fp
		coordinator_status: { state: health.state, program: f.program, version: f.model }
		connector_version: CONNECTOR_VERSION
	})

	# Re-enroll safety: if the admin explicitly passed --workspace-id, AION must
	# have returned the same id (the enrollment token binds the workspace server-side).
	# Mismatch means the admin pasted the wrong id or used a token from a different
	# workspace — fail loudly rather than silently enrolling into a different record.
	if f['workspace-id'] and reg.workspace_id !== f['workspace-id']
		error("workspace-id mismatch: expected {f['workspace-id']}, AION returned {reg.workspace_id}")
		process.exit(1)

	stateMod.writeState({
		workspace_id: reg.workspace_id
		workspace_token: reg.workspace_token
		aion_token: reg.aion_token
		aion_url: f.aion
		port: port
		cert_fingerprint: fp
		coordinator: {
			program: f.program
			model: f.model
			auth_mode: f['auth-mode']
		}
	})
	console.log("READY workspace_id={reg.workspace_id} port={port} fingerprint={fp}")

def cmdStatus
	const st = stateMod.readState()
	unless st
		console.error("no workspace state")
		process.exit(1)
	console.log("workspace_id: {st.workspace_id}")
	console.log("aion_url:     {st.aion_url}")
	console.log("port:         {st.port}")
	console.log("coordinator:  {st.coordinator.program} ({st.coordinator.model})")
	console.log("fingerprint:  {st.cert_fingerprint}")
	try
		const s = await exec(['systemctl', '--user', 'is-active', 'aion-connector.service'])
		console.log("unit active:  {s.stdout.trim() or s.stderr.trim()}")
	catch e
		console.log("unit active:  (systemctl unavailable: {e.message})")

def cmdLogs flags
	const n = flags.n or '100'
	const p = spawn('journalctl', ['--user', '-u', 'aion-connector.service', '-n', n, '-f'], { stdio: 'inherit' })
	p.on('close', do(code) process.exit(code))

def pidOfRun
	const r = await exec(['systemctl', '--user', 'show', 'aion-connector.service', '--property=MainPID', '--value'])
	parseInt(r.stdout.trim()) or 0

def cmdRestart flags
	if flags.coordinator
		const pid = await pidOfRun()
		if pid > 0
			process.kill(pid, 'SIGHUP')
		return
	const r = await exec(['systemctl', '--user', 'restart', 'aion-connector.service'])
	process.exit(r.exitCode)

def cmdStop
	const r = await exec(['systemctl', '--user', 'stop', 'aion-connector.service'])
	process.exit(r.exitCode)

def cmdDoctor
	const st = stateMod.readState()
	if !st
		console.error("FAIL: no workspace state")
		process.exit(1)
	let ok = yes
	# AION reachability
	try
		const res = await _fetch("{st.aion_url}/api/workspaces/{st.workspace_id}/heartbeat",
			{
				method: 'POST'
				headers: { 'content-type': 'application/json', 'authorization': "Bearer {st.workspace_token}" }
				body: JSON.stringify({ external_ip: process.env.AION_EXTERNAL_IP or '0.0.0.0', coordinator_status: { state: 'starting' }, connector_version: CONNECTOR_VERSION, timestamp: Date.now() })
			}
		)
		const aionTag = if res.status == 200 then 'OK' else "FAIL {res.status}"
		console.log("aion reach:    {aionTag}")
		ok = ok and res.status == 200
	catch e
		console.log("aion reach:    FAIL ({e.message})")
		ok = no
	# TLS cert fingerprint
	try
		const fp = await tls.fingerprint(stateMod.certPath())
		const match = fp == st.cert_fingerprint
		const certTag = if match then 'OK' else 'FAIL (pin mismatch)'
		console.log("tls cert:      {certTag}")
		ok = ok and match
	catch e
		console.log("tls cert:      FAIL ({e.message})")
		ok = no
	# Adapter health
	try
		const home = process.env.HOME or homedir()
		const adapter = makeAdapter(st.coordinator.program, home)
		const h = await adapter.health()
		const adapterTag = if h.state == 'ready' then 'OK' else "FAIL {h.detail or h.state}"
		console.log("coordinator:   {adapterTag}")
		ok = ok and h.state == 'ready'
	catch e
		console.log("coordinator:   FAIL ({e.message})")
		ok = no
	process.exit(ok ? 0 : 1)

def cmdUninstall
	const st = stateMod.readState()
	if st
		try
			await _fetch("{st.aion_url}/api/workspaces/{st.workspace_id}", {
				method: 'DELETE'
				headers: { 'authorization': "Bearer {st.workspace_token}" }
			})
		catch e
			console.error("warning: failed to notify AION: {e.message}")
	const home = process.env.HOME or homedir()
	try
		await exec(['systemctl', '--user', 'stop', 'aion-connector.service'])
	catch e
		yes
	try
		await exec(['systemctl', '--user', 'disable', 'aion-connector.service'])
	catch e
		yes
	const unit = join(home, '.config', 'systemd', 'user', 'aion-connector.service')
	if existsSync(unit)
		unlinkSync(unit)
	rmSync(stateMod.stateDir(), { recursive: yes, force: yes })
	rmSync(join(home, 'coordinator'), { recursive: yes, force: yes })
	console.log("uninstalled — re-run installer with --workspace-id to re-enroll")

# Dispatcher runs after all defs are declared.
const sub = process.argv[2]
if sub === 'run'
	await cmdRun()
elif sub === 'install'
	await cmdInstall(parseFlags(process.argv.slice(3)))
elif sub === 'status'
	await cmdStatus()
elif sub === 'logs'
	await cmdLogs(parseFlags(process.argv.slice(3)))
elif sub === 'restart'
	await cmdRestart(parseFlags(process.argv.slice(3)))
elif sub === 'stop'
	await cmdStop()
elif sub === 'doctor'
	await cmdDoctor()
elif sub === 'uninstall'
	await cmdUninstall()
else
	usage()
