import {Connector} from './connector.imba'
import {log, error} from './utils.imba'
import {existsSync, readFileSync} from 'fs'

# Find config file
const configPath = process.argv[2] or "./aion.config.json"

unless existsSync(configPath)
	console.error "Config file not found: {configPath}"
	console.error ""
	console.error "Usage: aion-connector [config-path]"
	console.error "  Default: ./aion.config.json"
	console.error ""
	console.error "Config format:"
	console.error '  \{'
	console.error '    "port": 7777,'
	console.error '    "projects": \{'
	console.error '      "PROJECT_ID": \{'
	console.error '        "token": "secret",'
	console.error '        "dir": "./projects/name",'
	console.error '        "agents": \{'
	console.error '          "qwen": \{ "description": "Qwen 3 Coder" \}'
	console.error '        \}'
	console.error '      \}'
	console.error '    \}'
	console.error '  \}'
	process.exit(1)

let config
try
	config = JSON.parse(readFileSync(configPath, 'utf8'))
catch e
	error "Failed to parse config: {e.message}"
	process.exit(1)

unless config.projects and Object.keys(config.projects).length
	error "Config must have at least one project"
	process.exit(1)

import {shutdownAllAgents} from './agent.imba'

const connector = new Connector(config)
await connector.start!

# Graceful shutdown — close all agent sessions before exit
const shutdown = do
	log "shutting down..."
	await shutdownAllAgents!
	connector.stop!
	process.exit(0)

process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
