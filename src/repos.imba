import {join} from 'path'
import {log, error, exec} from './utils.imba'
import {existsSync, mkdirSync} from 'fs'

export class Repos
	#dir = null
	#map = {}

	def constructor dir
		#dir = dir
		unless existsSync(dir)
			mkdirSync(dir, recursive: yes)
			log "created workspace dir: {dir}"

	def sync list
		for repo in list
			const folder = repodir(repo.url) or repo.name
			const dest = join(#dir, folder)
			if existsSync(dest)
				await pull(dest, repo)
			else
				await clone(repo, dest)
			#map[repo.name] = dest

	def clone repo, dest
		const url = inject(repo.url, repo.token)
		const branch = repo.branch or "main"
		log "cloning {repo.name} ({branch})"
		const result = await exec(["git", "clone", "-b", branch, url, dest])
		if result.exitCode != 0
			error "clone failed: {result.stderr}"

	def pull dest, repo = null
		log "pulling {dest}"
		await exec(["git", "pull"], cwd: dest)

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

	def repodir url
		return null unless url
		const parts = url.replace(/\.git$/, '').split('/')
		parts[parts.length - 1] if parts.length

	def head dir
		const result = await exec(["git", "rev-parse", "HEAD"], cwd: dir)
		result.stdout.trim!
