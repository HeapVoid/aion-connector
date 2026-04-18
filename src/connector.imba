# Orchestrator. Owns: state, adapter, server, aion client, heartbeat loop.
import * as stateMod from './state.imba'
import * as tls from './tls.imba'
import * as portMod from './port.imba'
import * as aionMod from './aion-client.imba'
import * as serverMod from './server.imba'
import * as hbMod from './heartbeat.imba'
import * as adapterMod from './adapter.imba'
import * as routesMod from './routes.imba'
import {log} from './utils.imba'
import {readFileSync} from 'fs'
import {join, dirname} from 'path'
import {fileURLToPath} from 'url'
import {homedir} from 'os'

const __dir = dirname(fileURLToPath(import.meta.url))
const pkg = JSON.parse(readFileSync(join(__dir, '..', 'package.json'), 'utf8'))
export const CONNECTOR_VERSION = pkg.version

const _fetch = globalThis.fetch.bind(globalThis)

export class Connector
	state = null
	adapter = null
	server = null
	aionClient = null
	heartbeat = null
	externalIp = null

	def constructor st
		self.state = st

	def start
		const ck = tls.loadCertKey(stateMod.certPath(), stateMod.keyPath())
		const home = process.env.HOME or homedir()
		adapter = adapterMod.makeAdapter(state.coordinator.program, home)
		externalIp = await self.detectIp()
		aionClient = new aionMod.AionClient(state.aion_url, state.workspace_token)
		server = new serverMod.Server({ port: state.port, cert: ck.cert, key: ck.key, aionToken: state.aion_token })
		routesMod.registerRoutes(server, self)
		await server.start()
		log("server up on :{state.port}")
		const self2 = self
		heartbeat = new hbMod.Heartbeat({
			aionClient: aionClient
			workspaceId: state.workspace_id
			intervalMs: 30000
			collect: do self2.collectHeartbeat()
		})
		heartbeat.start()
		log("heartbeat started")

	def stop
		if heartbeat
			heartbeat.stop()
		if server
			await server.stop()
		if adapter and adapter.stop
			await adapter.stop()

	def collectHeartbeat
		const h = await adapter.health()
		{
			external_ip: externalIp
			coordinator_status: {
				state: h.state
				detail: h.detail
				program: state.coordinator.program
				version: state.coordinator.version
			}
			connector_version: CONNECTOR_VERSION
		}

	def detectIp
		if process.env.AION_EXTERNAL_IP
			return process.env.AION_EXTERNAL_IP
		try
			const res = await _fetch('https://ifconfig.me/ip')
			if res.ok
				const txt = (await res.text()).trim()
				if txt
					return txt
		catch e
			# swallow — fall through to fallback
		'0.0.0.0'
