const { execSync } = require("child_process")
const fs = require("fs")
const os = require("os")
const path = require("path")
const readline = require("readline")

// detect "yes" flags
const autoYes = process.argv.includes("-y")

// detect nightly flag
const isNightly = process.argv.includes("--nightly")

// detect editor command from args or default to "code"
const editorArg = process.argv.find((arg) => arg.startsWith("--editor="))
const defaultEditor = editorArg ? editorArg.split("=")[1] : "code"

const rl = readline.createInterface({
	input: process.stdin,
	output: process.stdout,
})

const askQuestion = (question) => {
	return new Promise((resolve) => {
		rl.question(question, (answer) => {
			resolve(answer)
		})
	})
}

const atlasEnabled = () => !["0", "false", "FALSE", "no", "NO"].includes(process.env.ROO_INSTALL_ATLAS || "1")

const execText = (command) => execSync(command, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim()

const atlasReleasePlatform = () => {
	const platform = process.platform
	if (!["darwin", "linux"].includes(platform)) {
		throw new Error(`Atlas auto-install does not support ${platform}; set ROO_INSTALL_ATLAS=0 to skip`)
	}
	const arch = process.arch === "x64" ? "amd64" : process.arch
	if (!["amd64", "arm64"].includes(arch)) {
		throw new Error(`Atlas auto-install does not support ${process.arch}; set ROO_INSTALL_ATLAS=0 to skip`)
	}
	return { os: platform, arch }
}

const resolveAtlasCommand = () => {
	if (process.env.ATLAS_BIN && fs.existsSync(process.env.ATLAS_BIN)) {
		return process.env.ATLAS_BIN
	}
	try {
		return execText("command -v atlas")
	} catch {
		return ""
	}
}

const installAtlas = () => {
	if (!atlasEnabled()) {
		console.log("Skipping Atlas install/configuration because ROO_INSTALL_ATLAS=0")
		return ""
	}

	const existing = resolveAtlasCommand()
	if (existing) {
		console.log(`Atlas found at ${existing}`)
		return existing
	}

	const repo = process.env.ROO_ATLAS_REPO || "dominic097/atlas"
	const release = process.env.ROO_ATLAS_VERSION || "latest"
	const version =
		release === "latest"
			? JSON.parse(execText(`curl -fsSL https://api.github.com/repos/${repo}/releases/latest`)).tag_name.replace(
					/^v/,
					"",
				)
			: release.replace(/^v/, "")
	const target = atlasReleasePlatform()
	const archive = `atlas_${version}_${target.os}_${target.arch}.tar.gz`
	const url = `https://github.com/${repo}/releases/download/v${version}/${archive}`
	const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "atlas-install-"))
	const binDir = process.env.ROO_BIN_DIR || path.join(os.homedir(), ".local", "bin")
	const atlasPath = path.join(binDir, "atlas")

	try {
		console.log(`Installing Atlas ${version} from ${url}`)
		execSync(`curl -fsSL "${url}" -o "${path.join(tmp, archive)}"`, { stdio: "inherit" })
		execSync(`tar -xzf "${path.join(tmp, archive)}" -C "${tmp}"`, { stdio: "inherit" })
		fs.mkdirSync(binDir, { recursive: true })
		fs.copyFileSync(path.join(tmp, "atlas"), atlasPath)
		fs.chmodSync(atlasPath, 0o755)
		return atlasPath
	} finally {
		fs.rmSync(tmp, { recursive: true, force: true })
	}
}

const globalStorageBases = (editorCommand) => {
	const explicit = String(process.env.ROO_ATLAS_MCP_STORAGE_DIRS || "").trim()
	if (explicit) return explicit.split(path.delimiter).filter(Boolean)

	if (process.platform === "darwin") {
		const app = editorCommand.includes("cursor")
			? "Cursor"
			: editorCommand.includes("insiders")
				? "Code - Insiders"
				: "Code"
		const base = path.join(os.homedir(), "Library", "Application Support", app, "User", "globalStorage")
		return [path.join(base, "aziro.fusionx"), path.join(base, "aziro.fusionx-cline")]
	}

	const app = editorCommand.includes("cursor")
		? "Cursor"
		: editorCommand.includes("insiders")
			? "Code - Insiders"
			: "Code"
	const baseName = app === "Code" ? "Code" : app
	const configBase = path.join(os.homedir(), ".config", baseName, "User", "globalStorage")
	return [path.join(configBase, "aziro.fusionx"), path.join(configBase, "aziro.fusionx-cline")]
}

const configureAtlasMcp = (atlasCommand, editorCommand) => {
	if (!atlasEnabled() || !atlasCommand) return
	const serverName = process.env.ROO_ATLAS_MCP_SERVER_NAME || "pulse-atlas"
	const server = {
		type: "stdio",
		command: atlasCommand,
		args: ["mcp", "--transport", "stdio", "--db", "sqlite://${workspaceFolder}/.atlas/atlas.db"],
		cwd: "${workspaceFolder}",
		alwaysAllow: [
			"context",
			"search",
			"semantic_search",
			"symbol",
			"callers",
			"neighbors",
			"path",
			"refs",
			"explain",
			"impact",
			"cross_repo_impact",
			"status",
		],
		timeout: 120,
	}

	for (const dir of globalStorageBases(editorCommand)) {
		const settingsDir = path.join(dir, "settings")
		fs.mkdirSync(settingsDir, { recursive: true })
		const file = path.join(settingsDir, "mcp_settings.json")
		let root = {}
		if (fs.existsSync(file)) {
			try {
				root = JSON.parse(fs.readFileSync(file, "utf8"))
			} catch {
				root = {}
			}
		}
		if (!root || typeof root !== "object" || Array.isArray(root)) root = {}
		if (!root.mcpServers || typeof root.mcpServers !== "object" || Array.isArray(root.mcpServers)) {
			root.mcpServers = {}
		}
		root.mcpServers[serverName] = server
		fs.writeFileSync(file, `${JSON.stringify(root, null, 2)}\n`)
		console.log(`Registered ${serverName} in ${file}`)
	}
}

async function main() {
	try {
		let name, version, publisher

		if (isNightly) {
			// For nightly, read the nightly-specific package.json and get publisher from src
			const nightlyPackageJson = JSON.parse(
				fs.readFileSync("./apps/vscode-nightly/package.nightly.json", "utf-8"),
			)
			const srcPackageJson = JSON.parse(fs.readFileSync("./src/package.json", "utf-8"))
			name = nightlyPackageJson.name
			version = nightlyPackageJson.version
			publisher = srcPackageJson.publisher
		} else {
			const packageJson = JSON.parse(fs.readFileSync("./src/package.json", "utf-8"))
			name = packageJson.name
			version = packageJson.version
			publisher = packageJson.publisher
		}

		const vsixFileName = `./bin/${name}-${version}.vsix`
		const extensionId = `${publisher}.${name}`
		const buildType = isNightly ? "Nightly" : "Regular"

		console.log(`\n🚀 Roo Code VSIX Installer (${buildType})`)
		console.log("========================")
		console.log("\nThis script will:")
		console.log("1. Uninstall any existing version of the Roo Code extension")
		console.log("2. Install the newly built VSIX package")
		console.log(`\nExtension: ${extensionId}`)
		console.log(`VSIX file: ${vsixFileName}`)

		// Ask for editor command if not provided
		let editorCommand = defaultEditor
		if (!editorArg && !autoYes) {
			const editorAnswer = await askQuestion(
				"\nWhich editor command to use? (code/cursor/code-insiders) [default: code]: ",
			)
			if (editorAnswer.trim()) {
				editorCommand = editorAnswer.trim()
			}
		}

		// skip prompt if auto-yes
		const answer = autoYes ? "y" : await askQuestion("\nDo you wish to continue? (y/n): ")

		if (answer.toLowerCase() !== "y") {
			console.log("Installation cancelled.")
			rl.close()
			process.exit(0)
		}

		console.log(`\nProceeding with installation using '${editorCommand}' command...`)

		try {
			execSync(`${editorCommand} --uninstall-extension ${extensionId}`, { stdio: "inherit" })
		} catch (e) {
			console.log("Extension not installed, skipping uninstall step")
		}

		if (!fs.existsSync(vsixFileName)) {
			console.error(`\n❌ VSIX file not found: ${vsixFileName}`)
			console.error("Make sure the build completed successfully")
			rl.close()
			process.exit(1)
		}

		execSync(`${editorCommand} --install-extension ${vsixFileName}`, { stdio: "inherit" })
		const atlasCommand = installAtlas()
		configureAtlasMcp(atlasCommand, editorCommand)

		console.log(`\n✅ Successfully installed extension from ${vsixFileName}`)
		console.log("\n⚠️  IMPORTANT: You need to restart VS Code for the changes to take effect.")
		console.log("   Please close and reopen VS Code to use the updated extension.\n")

		rl.close()
	} catch (error) {
		console.error("\n❌ Failed to install extension:", error.message)
		rl.close()
		process.exit(1)
	}
}

main()
