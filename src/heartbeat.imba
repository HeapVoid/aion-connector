import {error} from './utils.imba'

const _setInterval = globalThis.setInterval.bind(globalThis)
const _clearInterval = globalThis.clearInterval.bind(globalThis)

# Fires heartbeat() every intervalMs. `collect()` returns the payload object.
# Swallows errors (network blips shouldn't crash the connector).
export class Heartbeat
	interval = 30000
	timer = null
	aionClient = null
	workspaceId = null
	collect = null

	def constructor opts
		self.aionClient = opts.aionClient
		self.workspaceId = opts.workspaceId
		self.collect = opts.collect
		self.interval = opts.intervalMs or 30000

	def start
		const self2 = self
		self.tick!
		const cb = do self2.tick()
		timer = _setInterval(cb, interval)

	def stop
		if timer
			_clearInterval(timer)
			timer = null

	def tick
		try
			const payload = await collect()
			await aionClient.heartbeat(workspaceId, payload)
		catch e
			error("heartbeat failed: {e.message}")
