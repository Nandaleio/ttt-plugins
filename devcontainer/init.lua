local ttt = require("ttt")
local automation = require("ttt.automation")
local fs = require("ttt.fs")
local json = require("ttt.json")
local settings = require("ttt.settings")
local sys = require("ttt.system")
local term = require("ttt.terminal")

local RUNTIME_KEY = "devcontainer.runtime"
local LABEL_FOLDER = "devcontainer.local_folder"
local LABEL_CONFIG = "devcontainer.config_file"
local LOG_LIMIT = 300
-- Keeps the container alive and exits promptly on `stop`.
local KEEP_ALIVE = 'trap "exit 0" TERM; while sleep 1 & wait $!; do :; done'
local LOGIN_SHELL = "command -v bash >/dev/null 2>&1 && exec bash -l; exec sh -l"

local state = {
	loaded = false,
	entries = {},
	selected = nil,
	model = nil,
	config_error = nil,
	container = nil,
	runtime_error = nil,
	log = {},
	op = nil,
}
local last_panel = nil
local refresh_generation = 0
local refresh_waiters = {}

local function redraw()
	if last_panel then
		last_panel:redraw()
	end
end

local function runtime()
	if settings.get(RUNTIME_KEY) == "podman" then
		return "podman"
	end
	return "docker"
end

-- Text and path helpers

local function sorted_keys(tbl)
	local keys = {}
	for key in pairs(tbl) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function basename(path)
	return (path:gsub("/+$", ""):match("[^/]+$")) or path
end

local function dirname(path)
	return path:match("^(.*)/[^/]*$") or "."
end

local function resolve_path(base, path)
	if path:sub(1, 1) == "/" then
		return path
	end
	return base .. "/" .. path
end

local function first_line(text)
	local trimmed = (text or ""):gsub("^%s+", "")
	return trimmed:match("^[^\r\n]+") or ""
end

local function hash(text)
	local value = 5381
	for index = 1, #text do
		value = (value * 33 + text:byte(index)) % 4294967296
	end
	return string.format("%08x", value)
end

local function sanitize(line)
	return (line:gsub("\27%[[%d;?]*[%a]", ""):gsub("%c", " "))
end

local function append_log(text)
	for line in text:gmatch("[^\r\n]+") do
		table.insert(state.log, sanitize(line))
	end
	while #state.log > LOG_LIMIT do
		table.remove(state.log, 1)
	end
	redraw()
end

-- devcontainer.json is JSONC: remove comments and trailing commas outside strings.
local function strip_jsonc(text)
	local out = {}
	local index, length = 1, #text
	local in_string = false
	while index <= length do
		local char = text:sub(index, index)
		if in_string then
			table.insert(out, char)
			if char == "\\" then
				table.insert(out, text:sub(index + 1, index + 1))
				index = index + 1
			elseif char == '"' then
				in_string = false
			end
			index = index + 1
		elseif char == '"' then
			in_string = true
			table.insert(out, char)
			index = index + 1
		elseif text:sub(index, index + 1) == "//" then
			index = text:find("\n", index, true) or length + 1
		elseif text:sub(index, index + 1) == "/*" then
			local _, close = text:find("*/", index + 2, true)
			index = (close or length) + 1
		elseif char == "}" or char == "]" then
			local last = #out
			while last > 0 and out[last]:match("^%s$") do
				last = last - 1
			end
			if last > 0 and out[last] == "," then
				out[last] = " "
			end
			table.insert(out, char)
			index = index + 1
		else
			table.insert(out, char)
			index = index + 1
		end
	end
	return table.concat(out)
end

local function env_lookup(rest, source)
	local name, default = rest:match("^([^:]*):(.*)$")
	name = name or rest
	local value = source(name)
	if value == nil or value == "" then
		return default or ""
	end
	return value
end

-- Replaces ${...} in every string. Unknown variables stay as written, which
-- also leaves ${containerEnv:...} in place until the container exists.
local function substitute(value, variables)
	if type(value) == "string" then
		return (value:gsub("%${([^}]+)}", function(expression)
			local name, rest = expression:match("^([%w]+):(.*)$")
			if name == "localEnv" or name == "env" then
				return env_lookup(rest, sys.env)
			end
			if name == "containerEnv" and variables.container_env then
				return env_lookup(rest, function(key)
					return variables.container_env[key]
				end)
			end
			return variables[expression]
		end))
	end
	if type(value) == "table" then
		local out = {}
		for key, item in pairs(value) do
			out[key] = substitute(item, variables)
		end
		return out
	end
	return value
end

-- Configuration

local function discover_configs(roots)
	local entries = {}
	local function add(root, path)
		local label = path:sub(#root + 2)
		if #roots > 1 then
			label = basename(root) .. "/" .. label
		end
		table.insert(entries, { root = root, path = path, label = label })
	end
	for _, root in ipairs(roots) do
		local default = root .. "/.devcontainer/devcontainer.json"
		if fs.exists(default) then
			add(root, default)
		end
		if fs.exists(root .. "/.devcontainer.json") then
			add(root, root .. "/.devcontainer.json")
		end
		local children = fs.list(root .. "/.devcontainer") or {}
		table.sort(children, function(a, b)
			return a.name < b.name
		end)
		for _, child in ipairs(children) do
			local nested = root .. "/.devcontainer/" .. child.name .. "/devcontainer.json"
			if child.is_dir and fs.exists(nested) then
				add(root, nested)
			end
		end
	end
	return entries
end

local function is_non_empty(value)
	return type(value) == "table" and next(value) ~= nil
end

local function load_model(entry)
	local source, read_error = fs.read(entry.path)
	if not source then
		return nil, "Cannot read config: " .. tostring(read_error)
	end
	local ok, raw, decode_error = pcall(json.decode, strip_jsonc(source))
	if not ok or type(raw) ~= "table" then
		return nil, "Invalid JSON: " .. tostring(ok and decode_error or raw)
	end
	if raw.dockerComposeFile then
		return nil, "Docker Compose configs are not supported"
	end

	local build = type(raw.build) == "table" and raw.build or {}
	local dockerfile = build.dockerfile or build.dockerFile or raw.dockerFile
	local context = build.context or raw.context or "."
	if not raw.image and not dockerfile then
		return nil, "Config needs an image or build.dockerfile"
	end

	local local_variables = {
		localWorkspaceFolder = entry.root,
		localWorkspaceFolderBasename = basename(entry.root),
	}
	local folder = raw.workspaceFolder
	if type(folder) == "string" then
		folder = substitute(folder, local_variables)
	else
		folder = "/workspaces/" .. basename(entry.root)
	end
	local_variables.containerWorkspaceFolder = folder
	local_variables.containerWorkspaceFolderBasename = basename(folder)
	local config = substitute(raw, local_variables)
	build = type(config.build) == "table" and config.build or {}

	local warnings = {}
	if is_non_empty(config.features) then
		table.insert(warnings, "features are ignored")
	end
	if config.initializeCommand then
		table.insert(warnings, "initializeCommand is ignored")
	end

	local config_dir = dirname(entry.path)
	local model = {
		name = type(config.name) == "string" and config.name or basename(entry.root),
		image = config.image,
		folder = folder,
		mount = config.workspaceMount,
		container_env = config.containerEnv or {},
		remote_env = config.remoteEnv or {},
		container_user = config.containerUser,
		remote_user = config.remoteUser or config.containerUser,
		mounts = config.mounts or {},
		run_args = config.runArgs or {},
		forward_ports = config.forwardPorts or {},
		app_port = config.appPort,
		override_command = config.overrideCommand ~= false,
		privileged = config.privileged == true,
		init = config.init == true,
		cap_add = config.capAdd or {},
		security_opt = config.securityOpt or {},
		lifecycle = config,
		warnings = warnings,
		build_args = build.args or {},
		build_target = build.target,
		build_options = build.options or {},
	}
	if dockerfile then
		dockerfile = substitute(dockerfile, local_variables)
		model.dockerfile = resolve_path(config_dir, dockerfile)
		model.context = resolve_path(config_dir, substitute(context, local_variables))
	end
	return model
end

-- Runtime arguments

local function append_all(target, values)
	for _, value in ipairs(values) do
		table.insert(target, tostring(value))
	end
end

local function append_flag(target, flag, value)
	table.insert(target, flag)
	table.insert(target, tostring(value))
end

local function append_env(target, env)
	for _, key in ipairs(sorted_keys(env)) do
		append_flag(target, "-e", key .. "=" .. tostring(env[key]))
	end
end

local function mount_arg(mount)
	if type(mount) ~= "table" then
		return tostring(mount)
	end
	local parts = {}
	for _, key in ipairs(sorted_keys(mount)) do
		table.insert(parts, key .. "=" .. tostring(mount[key]))
	end
	return table.concat(parts, ",")
end

local function build_args(model, tag)
	local args = { "build", "-f", model.dockerfile, "-t", tag }
	if model.build_target then
		append_flag(args, "--target", model.build_target)
	end
	for _, key in ipairs(sorted_keys(model.build_args)) do
		append_flag(args, "--build-arg", key .. "=" .. tostring(model.build_args[key]))
	end
	append_all(args, model.build_options)
	table.insert(args, model.context)
	return args
end

local function run_args(model, entry, image)
	local args = {
		"run", "-d",
		"--label", LABEL_FOLDER .. "=" .. entry.root,
		"--label", LABEL_CONFIG .. "=" .. entry.path,
	}
	local mount = model.mount or ("type=bind,source=" .. entry.root .. ",target=" .. model.folder)
	if mount ~= "" then
		append_flag(args, "--mount", mount)
	end
	append_env(args, model.container_env)
	if model.container_user then
		append_flag(args, "--user", model.container_user)
	end
	for _, item in ipairs(model.mounts) do
		append_flag(args, "--mount", mount_arg(item))
	end
	-- Forwarded ports stay on loopback; appPort is published as written.
	for _, port in ipairs(model.forward_ports) do
		if type(port) == "number" then
			append_flag(args, "-p", string.format("127.0.0.1:%d:%d", port, port))
		end
	end
	local app_ports = type(model.app_port) == "table" and model.app_port or { model.app_port }
	for _, port in ipairs(app_ports) do
		if type(port) == "number" then
			append_flag(args, "-p", string.format("%d:%d", port, port))
		else
			append_flag(args, "-p", port)
		end
	end
	if model.privileged then
		table.insert(args, "--privileged")
	end
	if model.init then
		table.insert(args, "--init")
	end
	for _, capability in ipairs(model.cap_add) do
		append_flag(args, "--cap-add", capability)
	end
	for _, option in ipairs(model.security_opt) do
		append_flag(args, "--security-opt", option)
	end
	append_all(args, model.run_args)
	if model.override_command then
		append_flag(args, "--entrypoint", "/bin/sh")
		table.insert(args, image)
		table.insert(args, "-c")
		table.insert(args, KEEP_ALIVE)
	else
		table.insert(args, image)
	end
	return args
end

local function exec_prefix(model, container_id, env, interactive)
	local args = { "exec" }
	if interactive then
		table.insert(args, "-it")
	end
	if model.remote_user then
		append_flag(args, "-u", model.remote_user)
	end
	append_flag(args, "-w", model.folder)
	append_env(args, env)
	table.insert(args, container_id)
	return args
end

local function lifecycle_commands(value)
	if type(value) == "string" then
		return { { "/bin/sh", "-c", value } }
	end
	if type(value) ~= "table" then
		return {}
	end
	if value[1] ~= nil then
		return { value }
	end
	local commands = {}
	for _, key in ipairs(sorted_keys(value)) do
		for _, command in ipairs(lifecycle_commands(value[key])) do
			table.insert(commands, command)
		end
	end
	return commands
end

-- State refresh

local function selected_entry()
	for _, entry in ipairs(state.entries) do
		if entry.path == state.selected then
			return entry
		end
	end
	return state.entries[1]
end

local function finish_refresh(generation)
	if generation ~= refresh_generation then
		return
	end
	state.loaded = true
	local waiters = refresh_waiters
	refresh_waiters = {}
	redraw()
	for _, waiter in ipairs(waiters) do
		waiter()
	end
end

local function query_container(entry, generation, callback)
	local args = {
		"ps", "-a",
		"--filter", "label=" .. LABEL_FOLDER .. "=" .. entry.root,
		"--filter", "label=" .. LABEL_CONFIG .. "=" .. entry.path,
		"--format", "{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}",
	}
	sys.exec_async(runtime(), args, function(result)
		if generation ~= refresh_generation then
			return
		end
		state.container = nil
		state.runtime_error = nil
		if result.exit_code ~= 0 then
			state.runtime_error = first_line(result.stderr)
			if state.runtime_error == "" then
				state.runtime_error = runtime() .. " exited with " .. result.exit_code
			end
		else
			local id, name, status, image = first_line(result.stdout):match("^(.-)\t(.-)\t(.-)\t(.*)$")
			if id then
				state.container = {
					id = id,
					name = name,
					status = status,
					image = image,
					running = status:match("^Up") ~= nil,
				}
			end
		end
		callback()
	end)
end

local function refresh(callback)
	if callback then
		table.insert(refresh_waiters, callback)
	end
	refresh_generation = refresh_generation + 1
	local generation = refresh_generation
	automation.run("session", "", function(session, session_error)
		if generation ~= refresh_generation then
			return
		end
		if not session then
			ttt.log("error", "devcontainer: session: " .. tostring(session_error))
		end
		local roots = session and session.workspaces or {}
		state.entries = discover_configs(roots)
		state.model = nil
		state.config_error = nil
		state.container = nil
		state.runtime_error = nil
		local entry = selected_entry()
		if not entry then
			state.selected = nil
			finish_refresh(generation)
			return
		end
		state.selected = entry.path
		state.model, state.config_error = load_model(entry)
		query_container(entry, generation, function()
			finish_refresh(generation)
		end)
	end)
end

-- Operations. Only one runs at a time; each step streams into the log.

local function finish_op(message, level)
	local op = state.op
	state.op = nil
	if op and message then
		append_log(message)
		ttt.notify("Dev Container: " .. message, level or "info")
	end
	refresh()
end

local function begin_op(title)
	state.op = { title = title }
	state.log = {}
	append_log(title .. "...")
	return state.op
end

local function run_step(op, description, args, callback)
	if state.op ~= op then
		return
	end
	append_log(description)
	op.handle = sys.exec_async(runtime(), args, {
		on_stdout = append_log,
		on_stderr = append_log,
	}, function(result)
		op.handle = nil
		if state.op ~= op then
			return
		end
		if result.cancelled then
			finish_op(op.title .. " cancelled", "warn")
		elseif result.exit_code ~= 0 then
			if result.stderr ~= "" then
				append_log(result.stderr)
			end
			finish_op(op.title .. " failed", "error")
		else
			callback()
		end
	end)
end

local function container_env_of(container_id, callback)
	local args = { "inspect", "--format", "{{json .Config.Env}}", container_id }
	sys.exec_async(runtime(), args, function(result)
		local env = {}
		local ok, list = pcall(json.decode, result.stdout)
		if result.exit_code == 0 and ok and type(list) == "table" then
			for _, pair in ipairs(list) do
				local key, value = tostring(pair):match("^([^=]+)=(.*)$")
				if key then
					env[key] = value
				end
			end
		end
		callback(env)
	end)
end

local function with_remote_env(model, container_id, callback)
	if next(model.remote_env) == nil then
		callback({})
		return
	end
	container_env_of(container_id, function(container_env)
		callback(substitute(model.remote_env, { container_env = container_env }))
	end)
end

local function run_lifecycle(op, model, container_id, names, callback)
	with_remote_env(model, container_id, function(env)
		local steps = {}
		for _, name in ipairs(names) do
			for _, command in ipairs(lifecycle_commands(model.lifecycle[name])) do
				table.insert(steps, { name = name, command = command })
			end
		end
		local function run_next(index)
			local step = steps[index]
			if not step then
				callback()
				return
			end
			local args = exec_prefix(model, container_id, env, false)
			append_all(args, step.command)
			run_step(op, "Running " .. step.name, args, function()
				run_next(index + 1)
			end)
		end
		run_next(1)
	end)
end

local function require_model()
	if not selected_entry() then
		ttt.notify("No devcontainer.json in this workspace", "warn")
		return false
	end
	if state.runtime_error then
		ttt.notify(runtime() .. ": " .. state.runtime_error, "error")
		return false
	end
	if not state.model then
		ttt.notify(state.config_error or "Invalid devcontainer.json", "error")
		return false
	end
	return true
end

local function when_idle(callback)
	if state.op then
		ttt.notify(state.op.title .. " is still running", "warn")
		return
	end
	refresh(function()
		if state.op then
			ttt.notify(state.op.title .. " is still running", "warn")
		else
			callback()
		end
	end)
end

local function create_container(op, model, entry)
	local function start_new(image)
		run_step(op, "Creating container", run_args(model, entry, image), function()
			refresh_generation = refresh_generation + 1
			query_container(entry, refresh_generation, function()
				if not state.container then
					finish_op(op.title .. " failed: container not found", "error")
					return
				end
				run_lifecycle(op, model, state.container.id, {
					"onCreateCommand",
					"updateContentCommand",
					"postCreateCommand",
					"postStartCommand",
					"postAttachCommand",
				}, function()
					finish_op(model.name .. " is ready")
				end)
			end)
		end)
	end
	for _, warning in ipairs(model.warnings) do
		append_log("Warning: " .. warning)
	end
	if not model.dockerfile then
		start_new(model.image)
		return
	end
	local tag = "ttt-devcontainer-" .. hash(entry.root .. "\0" .. entry.path)
	run_step(op, "Building image", build_args(model, tag), function()
		start_new(tag)
	end)
end

local function cmd_up()
	when_idle(function()
		if not require_model() then
			return
		end
		local model, entry, container = state.model, selected_entry(), state.container
		if container and container.running then
			ttt.notify("Dev Container: " .. model.name .. " is already running")
			return
		end
		local op = begin_op(container and "Start" or "Up")
		if not container then
			create_container(op, model, entry)
			return
		end
		run_step(op, "Starting container", { "start", container.id }, function()
			run_lifecycle(op, model, container.id, { "postStartCommand", "postAttachCommand" }, function()
				finish_op(model.name .. " is ready")
			end)
		end)
	end)
end

local function cmd_rebuild()
	when_idle(function()
		if not require_model() then
			return
		end
		local model, entry, container = state.model, selected_entry(), state.container
		local function rebuild()
			if state.op then
				ttt.notify(state.op.title .. " is still running", "warn")
				return
			end
			local op = begin_op("Rebuild")
			if not container then
				create_container(op, model, entry)
				return
			end
			run_step(op, "Removing container", { "rm", "-f", container.id }, function()
				create_container(op, model, entry)
			end)
		end
		if container then
			ttt.confirm("Rebuild '" .. model.name .. "'? Changes outside mounts are lost.", rebuild, "Rebuild")
		else
			rebuild()
		end
	end)
end

local function cmd_stop()
	when_idle(function()
		local container = state.container
		if not container or not container.running then
			ttt.notify("Dev Container: no running container", "warn")
			return
		end
		local op = begin_op("Stop")
		run_step(op, "Stopping container", { "stop", container.id }, function()
			finish_op("Container stopped")
		end)
	end)
end

local function cmd_remove()
	when_idle(function()
		local container = state.container
		if not container then
			ttt.notify("Dev Container: no container to remove", "warn")
			return
		end
		ttt.confirm("Remove container '" .. container.name .. "'?", function()
			if state.op then
				ttt.notify(state.op.title .. " is still running", "warn")
				return
			end
			local op = begin_op("Remove")
			run_step(op, "Removing container", { "rm", "-f", container.id }, function()
				finish_op("Container removed")
			end)
		end, "Delete")
	end)
end

local function cmd_shell()
	when_idle(function()
		if not require_model() then
			return
		end
		local model, container = state.model, state.container
		if not container or not container.running then
			ttt.notify("Dev Container: start the container first", "warn")
			return
		end
		with_remote_env(model, container.id, function(env)
			local args = exec_prefix(model, container.id, env, true)
			append_all(args, { "/bin/sh", "-c", LOGIN_SHELL })
			local id, spawn_error = term.spawn({ shell = runtime(), args = args, label = "DC" })
			if not id then
				ttt.notify("Dev Container: " .. tostring(spawn_error), "error")
				return
			end
			term.focus(id)
		end)
	end)
end

local function cmd_open_config()
	refresh(function()
		local entry = selected_entry()
		if entry then
			ttt.open_file(entry.path)
		else
			ttt.notify("No devcontainer.json in this workspace", "warn")
		end
	end)
end

local function cmd_cancel()
	local op = state.op
	if op and op.handle then
		op.handle.cancel()
	end
end

local function set_runtime(next_runtime)
	if state.op then
		ttt.notify("Wait for " .. state.op.title .. " to finish", "warn")
		return
	end
	settings.set(RUNTIME_KEY, next_runtime)
	refresh()
end

local function cmd_switch_runtime()
	set_runtime(runtime() == "docker" and "podman" or "docker")
end

-- Rendering

local function button_row(panel, buttons)
	panel:hstack({
		height = 1,
		gap = 1,
		padding_left = 1,
		render = function(row)
			for _, button in ipairs(buttons) do
				row:button(button)
			end
		end,
	})
end

local function render_runtime_footer(panel)
	local active = runtime()
	panel:divider()
	panel:hstack({
		height = 1,
		padding_left = 1,
		padding_right = 1,
		render = function(row)
			row:label({ text = "Runtime", style = "muted" })
			row:dropdown({
				label = (active == "docker" and "Docker" or "Podman") .. " ▼",
				entries = {
					{ label = "Docker", command = "docker", checked = active == "docker" },
					{ label = "Podman", command = "podman", checked = active == "podman" },
				},
				on_menu = function(command)
					if command ~= runtime() then
						set_runtime(command)
					end
				end,
			})
		end,
	})
end

local function render_config_selector(panel)
	if #state.entries < 2 then
		return
	end
	local entries = {}
	for _, entry in ipairs(state.entries) do
		table.insert(entries, { label = entry.label, command = entry.path, checked = entry.path == state.selected })
	end
	panel:dropdown({
		label = selected_entry().label .. " ▼",
		entries = entries,
		on_menu = function(path)
			if state.op then
				ttt.notify("Wait for " .. state.op.title .. " to finish", "warn")
				return
			end
			state.selected = path
			refresh()
		end,
	})
end

local function status_text()
	if state.runtime_error then
		return "Unavailable"
	end
	if not state.container then
		return "Not created"
	end
	return state.container.running and "Running" or "Stopped"
end

local function render_details(panel)
	local entry = selected_entry()
	local rows = {
		{ key = "Name", value = state.model and state.model.name or basename(entry.root) },
		{ key = "Config", value = entry.label },
		{ key = "Status", value = status_text() },
	}
	if state.container then
		table.insert(rows, { key = "Container", value = state.container.name })
		table.insert(rows, { key = "Image", value = state.container.image })
	end
	panel:keyvalue(rows)
	if state.config_error then
		panel:label({ text = state.config_error, style = "danger", padding_left = 1 })
	end
	if state.runtime_error then
		panel:label({ text = runtime() .. ": " .. state.runtime_error, style = "danger", padding_left = 1 })
	end
	if state.model then
		for _, warning in ipairs(state.model.warnings) do
			panel:label({ text = "Warning: " .. warning, style = "warning", padding_left = 1 })
		end
	end
end

local function render_actions(panel)
	local busy = state.op ~= nil
	local usable = state.model ~= nil and not state.runtime_error and not busy
	local container = state.container
	local running = container ~= nil and container.running
	button_row(panel, {
		{ label = container and "Start" or "Up", style = "bracket", disabled = not usable or running, on_click = cmd_up },
		{ label = "Rebuild", style = "bracket", disabled = not usable, on_click = cmd_rebuild },
	})
	button_row(panel, {
		{ label = "Stop", style = "bracket", disabled = busy or not running, on_click = cmd_stop },
		{ label = "Remove", style = "bracket", disabled = busy or not container, on_click = cmd_remove },
	})
	button_row(panel, {
		{ label = "Shell", style = "bracket", disabled = not usable or not running, on_click = cmd_shell },
		{ label = "Config", style = "bracket", on_click = cmd_open_config },
	})
	if busy then
		button_row(panel, { { label = "Cancel", style = "bracket", disabled = not state.op.handle, on_click = cmd_cancel } })
	end
end

local function render_log(panel)
	if #state.log == 0 then
		return
	end
	panel:divider()
	panel:scrollview({
		follow = true,
		render = function(view)
			for _, line in ipairs(state.log) do
				view:label({ text = line, style = "muted", padding_left = 1 })
			end
		end,
	})
end

ttt.register({
	sidebar = {
		title = "Dev Container",
		actions = {
			{ label = "Refresh", command = "refresh" },
			{ label = "Switch Docker / Podman", command = "switchRuntime" },
		},
		on_action = function(command)
			if command == "refresh" then
				refresh()
			elseif command == "switchRuntime" then
				cmd_switch_runtime()
			end
		end,
		on_event = function(event)
			if event.type == "key" and event.key == "r" and event.mod == nil then
				refresh()
			end
		end,
		render = function(panel)
			last_panel = panel
			if not state.loaded then
				if refresh_generation == 0 then
					refresh()
				end
				panel:label({ text = "Loading...", style = "muted", padding_left = 1 })
			elseif not selected_entry() then
				panel:label({ text = "No devcontainer.json found", style = "muted", padding_left = 1 })
				panel:label({ text = "Add .devcontainer/devcontainer.json, then press R", style = "muted", padding_left = 1 })
			else
				render_config_selector(panel)
				render_details(panel)
				panel:divider()
				render_actions(panel)
				render_log(panel)
			end
			render_runtime_footer(panel)
		end,
	},
	commands = {
		{ id = "devcontainer.up", title = "Dev Container: Up", handler = cmd_up },
		{ id = "devcontainer.rebuild", title = "Dev Container: Rebuild", handler = cmd_rebuild },
		{ id = "devcontainer.stop", title = "Dev Container: Stop", handler = cmd_stop },
		{ id = "devcontainer.remove", title = "Dev Container: Remove", handler = cmd_remove },
		{ id = "devcontainer.shell", title = "Dev Container: Open Shell", handler = cmd_shell },
		{ id = "devcontainer.openConfig", title = "Dev Container: Open Config", handler = cmd_open_config },
		{ id = "devcontainer.cancel", title = "Dev Container: Cancel", handler = cmd_cancel },
		{ id = "devcontainer.refresh", title = "Dev Container: Refresh", handler = function() refresh() end },
		{ id = "devcontainer.switchRuntime", title = "Dev Container: Switch Runtime (Docker / Podman)", handler = cmd_switch_runtime },
	},
})

ttt.on_uninstall(function()
	settings.set(RUNTIME_KEY, nil)
end)
