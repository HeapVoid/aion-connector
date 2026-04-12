import {Repos} from './repos.imba'
import {Files} from './files.imba'
import {Server} from './server.imba'
import {Agent} from './agent.imba'
import {log, error} from './utils.imba'
import {join} from 'path'
import {mkdirSync, existsSync} from 'fs'

export class Connector
	port = 7777
	host = "0.0.0.0"
	server = null

	# Config-based project map: projectId → { token, dir, agents }
	#projects = {}
	# Token → projectId lookup for fast auth
	#tokens = {}
	# Runtime workspace cache: projectId → { repos, files, dir }
	#workspaces = {}

	def constructor config
		port = config.port or 7777
		host = config.host or "0.0.0.0"

		for own pid, proj of (config.projects or {})
			unless proj.token and proj.dir
				error "project {pid}: token and dir are required"
				continue
			#projects[pid] = {
				token: proj.token
				dir: proj.dir
				agents: proj.agents or {}
			}
			#tokens[proj.token] = pid

		if Object.keys(#projects).length == 0
			error "no valid projects configured"
			process.exit(1)

	def start
		server = new Server(self)
		await server.start!
		const pids = Object.keys(#projects)
		let total = 0
		for own pid, proj of #projects
			total += Object.keys(proj.agents).length
		log "ready: {pids.length} project(s), {total} agent(s)"

	def stop
		server..stop!

	# Authenticate token → returns projectId or null
	def auth token
		#tokens[token] or null

	# Get project config by id
	def project pid
		#projects[pid]

	# Get or create workspace for a project
	def workspace pid
		return #workspaces[pid] if #workspaces[pid]
		const proj = #projects[pid]
		return null unless proj
		const dir = proj.dir
		unless existsSync(dir)
			mkdirSync(dir, recursive: yes)
		const repos = new Repos(dir)
		const files = new Files(repos)
		#workspaces[pid] = { repos, files, dir }

	# List agents available for a project
	def agents pid
		const proj = #projects[pid]
		return [] unless proj
		Object.entries(proj.agents).map do([name, cfg])
			{ name, description: cfg.description or "" }

	# Check if agent is valid for a project
	def validAgent pid, name
		const proj = #projects[pid]
		return no unless proj
		proj.agents[name] ? yes : no

	def invoke payload
		const pid = payload.project
		unless pid and #projects[pid]
			error "invoke: unknown project {pid}"
			return

		const agentName = payload.agent
		unless agentName
			error "invoke: no agent specified"
			return

		unless validAgent(pid, agentName)
			error "invoke: agent '{agentName}' not available for project {pid}"
			return

		const ws = workspace(pid)
		await ws.repos.sync(payload.repos or [])
		const ag = new Agent(self)
		ag.invoke(payload, ws)

	def filesFor pid
		const ws = workspace(pid)
		return null unless ws
		ws.files

	def reposFor pid
		const ws = workspace(pid)
		return null unless ws
		ws.repos
