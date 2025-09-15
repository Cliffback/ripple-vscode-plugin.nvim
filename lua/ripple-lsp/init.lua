local M = {}

local fn = vim.fn

local data_dir = fn.stdpath("data") .. "/ripple-lsp"
local vsix_path = data_dir .. "/vsix/ripple.vsix"
local vendor_dir = data_dir .. "/vendor/ripple-vscode-plugin"

-- Helper to run shell commands
local function system(cmd)
	local output = fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("Error running: " .. table.concat(cmd, " ") .. "\n" .. output, vim.log.levels.ERROR)
	end
	return output
end

-- If vendor directory isn't there, download + unzip
if fn.isdirectory(vendor_dir) == 0 then
	vim.notify("Installing ripple-vscode-plugin…", vim.log.levels.INFO)

	-- Make dirs
	fn.mkdir(data_dir .. "/vsix", "p")
	fn.mkdir(vendor_dir, "p")

	-- Download the VSIX
	-- Note: you may need the correct URL to the VSIX; this is a pattern many Marketplace extensions support
	local vsix_url =
	-- "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ripplejs/vsextensions/ripple-vscode-plugin/0.0.10/vspackage"
	"https://ripplejs.gallery.vsassets.io/_apis/public/gallery/publisher/ripplejs/extension/ripple-vscode-plugin/0.0.10/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"

	system({ "curl", "-L", vsix_url, "-o", vsix_path })

	-- Unzip to vendor_dir
	system({ "unzip", "-o", vsix_path, "-d", vendor_dir })
end



-- ---- WorkspaceEdit helpers -------------------------------------------------
local function normalize_ws_edit_full(edit)
	if type(edit) ~= 'table' then return end

	-- 1) Convert TextDocumentEdit entries in documentChanges -> changes (unversioned)
	if edit.documentChanges and type(edit.documentChanges) == 'table' then
		local kept_doc_changes = {}
		edit.changes = edit.changes or {}
		for _, dc in ipairs(edit.documentChanges) do
			-- TextDocumentEdit shape: { textDocument = { uri=..., version=... }, edits = { ... } }
			if dc.textDocument and dc.edits then
				local uri = dc.textDocument.uri
				edit.changes[uri] = edit.changes[uri] or {}
				for _, te in ipairs(dc.edits) do table.insert(edit.changes[uri], te) end
			else
				-- keep non-TextDocumentEdit entries (CreateFile, RenameFile, etc.)
				table.insert(kept_doc_changes, dc)
			end
		end
		if #kept_doc_changes > 0 then
			edit.documentChanges = kept_doc_changes
		else
			edit.documentChanges = nil
		end
	end

	-- 2) Recursively strip any 'version' field anywhere in the table
	local seen = {}
	local function strip_versions(obj)
		if type(obj) ~= 'table' then return end
		if seen[obj] then return end
		seen[obj] = true
		if obj.version ~= nil then obj.version = nil end
		for k, v in pairs(obj) do strip_versions(v) end
	end
	strip_versions(edit)
end

-- 3) Wrap apply_workspace_edit so any caller gets the cleaned edit
if not vim.g.ripple_lsp_apply_patched then
	vim.g.ripple_lsp_apply_patched = true
	local orig_apply = vim.lsp.util.apply_workspace_edit
	vim.lsp.util.apply_workspace_edit = function(edit, encoding, bufnr)
		-- defensive: normalize whatever we got
		pcall(normalize_ws_edit_full, edit)
		-- very helpful while debugging: uncomment the next line to log edits
		-- pcall(log_edit_for_debug, edit)
		return orig_apply(edit, encoding, bufnr)
	end

	-- Also wrap the client handler for server-initiated "workspace/applyEdit" requests
	local orig_handler = vim.lsp.handlers['workspace/applyEdit']
	vim.lsp.handlers['workspace/applyEdit'] = function(err, result, ctx, config)
		if result then
			-- result can be ApplyWorkspaceEditParams or a bare WorkspaceEdit depending on server
			local edit = result.edit or result
			pcall(normalize_ws_edit_full, edit)
			-- pcall(log_edit_for_debug, edit)
		end
		if orig_handler then
			return orig_handler(err, result, ctx, config)
		end
	end
end

-- 4) make sure your local apply wrapper (if you call it) uses bufnr when applying:
local function apply_ws_edit(edit, client, bufnr)
	if not edit then return end
	-- normalize one more time (harmless)
	pcall(normalize_ws_edit_full, edit)
	local enc = (client and client.offset_encoding) or "utf-16"
	return vim.lsp.util.apply_workspace_edit(edit, enc, bufnr)
end

-- Resolve a client even if ctx is missing
local function resolve_client(ctx)
	if ctx and ctx.client_id then
		local c = vim.lsp.get_client_by_id(ctx.client_id)
		if c then return c end
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local clients = vim.lsp.get_active_clients({ bufnr = bufnr })
	-- Prefer ripple if present
	for _, c in ipairs(clients) do
		if c.name == "ripple" then return c, bufnr end
	end
	return clients[1], bufnr
end

local function ensure_command(id, impl)
	vim.lsp.commands[id] = function(cmd, ctx)
		local client, bufnr = resolve_client(ctx)
		ctx = ctx or {}
		ctx.client_id = ctx.client_id or (client and client.id)
		ctx.bufnr = ctx.bufnr or bufnr
		return impl(cmd, ctx, client)
	end
end

local shims_installed = false
local function install_shims_once()
	if shims_installed then return end
	shims_installed = true

	-- TypeScript/Volar command IDs we see from code actions
	ensure_command('_typescript.applyWorkspaceEdit', function(cmd, ctx, client)
		apply_ws_edit(cmd.arguments and cmd.arguments[1], client, ctx.bufnr)
	end)

	ensure_command('_typescript.applyCodeAction', function(cmd, ctx, client)
		local action = cmd.arguments and cmd.arguments[1]
		if type(action) == 'table' then
			if action.edit then apply_ws_edit(action.edit, client, ctx.bufnr) end
			if action.command then
				client.request('workspace/executeCommand', action.command, function(err)
					if err then vim.notify(err.message, vim.log.levels.ERROR) end
				end, ctx.bufnr)
			end
		end
	end)

	ensure_command('_typescript.organizeImports', function(cmd, ctx, client)
		client.request('workspace/executeCommand', cmd, function(err)
			if err then vim.notify(err.message, vim.log.levels.ERROR) end
		end, ctx.bufnr)
	end)

	-- Some stacks use volar.* IDs for similar behaviors
	ensure_command('volar.applyWorkspaceEdit', function(cmd, ctx, client)
		apply_ws_edit(cmd.arguments and cmd.arguments[1], client, ctx.bufnr)
	end)
	ensure_command('volar.applyCodeAction', function(cmd, ctx, client)
		local action = cmd.arguments and cmd.arguments[1]
		if type(action) == 'table' then
			if action.edit then apply_ws_edit(action.edit, client, ctx.bufnr) end
			if action.command then
				client.request('workspace/executeCommand', action.command, function(err)
					if err then vim.notify(err.message, vim.log.levels.ERROR) end
				end, ctx.bufnr)
			end
		end
	end)
end

-- ---- Main setup ------------------------------------------------------------
function M.setup(opts)
	opts               = opts or {}
	local lspconfig    = require('lspconfig')
	local configs      = require('lspconfig.configs')

	local script_dir   = debug.getinfo(1, "S").source:match("@(.*/)")
	local utils_path   = script_dir .. "./ripple-lsp.cjs"
	local project_root = lspconfig.util.root_pattern("package.json", ".git")(vim.fn.getcwd())

	opts.cmd           = opts.cmd or { "node", utils_path, "--stdio", "--extRoot", vendor_dir .. "/extension/src" }
	opts.init_options  = opts.init_options or {
		ripplePath = project_root .. "/node_modules/ripple/src/compiler/index.js",
		typescript = { tsdk = project_root .. "/node_modules/typescript/lib" },
	}

	-- -- Required inputs
	-- assert(opts.cmd and opts.cmd[1], "[ripple_lsp] opts.cmd is required")
	-- assert(opts.init_options
	--   and opts.init_options.ripplePath
	--   and opts.init_options.typescript
	--   and opts.init_options.typescript.tsdk,
	--   "[ripple_lsp] opts.init_options.ripplePath and .typescript.tsdk are required")
	--
	local server_name  = opts.server_name or "ripple"
	local ts_lang      = (opts.treesitter_lang == nil) and "tsx" or opts.treesitter_lang
	local set_ft       = (opts.set_filetype ~= false)

	-- 1) Filetype + Tree-sitter alias (optional)
	if set_ft then
		local grp = vim.api.nvim_create_augroup('ripple_ft', { clear = true })
		vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
			group = grp,
			pattern = '*.ripple',
			callback = function(ev) vim.bo[ev.buf].filetype = 'ripple' end,
		})
	end
	local ok_reg = vim.treesitter and vim.treesitter.language
	    and type(vim.treesitter.language.register) == 'function'
	if ok_reg and ts_lang then
		pcall(vim.treesitter.language.register, ts_lang, 'ripple')
	end

	-- 2) Register the server if missing
	if not configs[server_name] then
		configs[server_name] = {
			default_config = {
				cmd = opts.cmd,
				filetypes = { 'ripple' },
				root_dir = lspconfig.util.root_pattern('package.json', '.git'),
				init_options = opts.init_options,
			},
			docs = { description = 'Ripple language server (Volar-based)' },
		}
	end

	-- 3) Capabilities (UTF-16 for TS/Volar)
	local capabilities = opts.capabilities
	if not capabilities then
		local ok_cmp, cmp = pcall(require, 'cmp_nvim_lsp')
		capabilities = ok_cmp and cmp.default_capabilities()
		    or vim.lsp.protocol.make_client_capabilities()
	end
	capabilities.general = capabilities.general or {}
	capabilities.general.positionEncodings = { 'utf-16', 'utf-8' }

	-- 4) Install shims as soon as Ripple attaches (and once only)
	local grp = vim.api.nvim_create_augroup('ripple_lsp_shims', { clear = true })
	vim.api.nvim_create_autocmd('LspAttach', {
		group = grp,
		callback = function(ev)
			local client = vim.lsp.get_client_by_id(ev.data.client_id)
			if client and client.name == server_name then
				install_shims_once()
			end
		end,
	})

	-- 5) Start the server
	local user_on_attach = opts.on_attach
	lspconfig[server_name].setup({
		capabilities = capabilities,
		on_attach = function(client, bufnr)
			if type(user_on_attach) == 'function' then
				pcall(user_on_attach, client, bufnr)
			end
			-- Optional: semantic tokens
			if client.server_capabilities.semanticTokensProvider then
				pcall(vim.lsp.semantic_tokens.start, bufnr, client.id)
			end
		end,
	})
end

return M
