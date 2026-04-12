import {join} from 'path'
import {log, error} from './utils.imba'
import {existsSync} from 'fs'

export class Repos
	#dir = null
	#map = {}

	def constructor dir
		#dir = dir

	def sync list
		for repo in list
			const dest = join(#dir, repo.name)
			if existsSync(dest)
				await pull(dest, repo)
			else
				await clone(repo, dest)
			#map[repo.name] = dest

	def clone repo, dest
		const url = inject(repo.url, repo.token)
		const branch = repo.branch or "main"
		log "cloning {repo.name} ({branch})"
		const proc = Bun.spawn(["git", "clone", "-b", branch, url, dest], stdout: "pipe", stderr: "pipe")
		await proc.exited
		if proc.exitCode != 0
			const err = await new Response(proc.stderr).text!
			error "clone failed: {err}"

	def pull dest, repo = null
		log "pulling {dest}"
		const proc = Bun.spawn(["git", "pull"], cwd: dest, stdout: "pipe", stderr: "pipe")
		await proc.exited

	def inject url, token
		return url unless token
		url.replace("https://", "https://{token}@")

	def resolve name
		if name
			#map[name] or primary!
		else
			primary!

	def primary
		const keys = Object.keys(#map)
		#map[keys[0]] if keys.length

	def list
		Object.entries(#map).map do([name, path]) { name, path }

	def head dir
		const proc = Bun.spawn(["git", "rev-parse", "HEAD"], cwd: dir, stdout: "pipe")
		const out = await new Response(proc.stdout).text!
		await proc.exited
		out.trim!
