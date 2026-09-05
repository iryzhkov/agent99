-- The symbol index: what agent99 knows about a file's structure without a
-- language server, and how it merges the server's view in when one is up.
--
-- Treesitter gives declaration-shaped nodes (functions, classes, sections of
-- a Markdown file); the server's document symbols add what the grammar
-- leaves out (constants, module-level variables, signatures). The index is
-- what skim, workspace_map, find_symbol, the name-path resolution every
-- edit tool uses, and the grep hit annotation all read.

local M = {}

local core = require("agent99.core")
local err, sleep, load_buf, rel_path = core.err, core.sleep, core.load_buf, core.rel_path
local get_client, request, client_for = core.get_client, core.request, core.client_for
local has_parser, expand_glob, decl_line = core.has_parser, core.expand_glob, core.decl_line
local project_files, is_test_path, better_sample = core.project_files, core.is_test_path, core.better_sample
local fresh_buf, DATA_FILETYPES, FRESH_RETRY_MS = core.fresh_buf, core.DATA_FILETYPES, core.FRESH_RETRY_MS
local enabled_lsp_configs_for = core.enabled_lsp_configs_for
local MAX_LOCATIONS, ATTACH_TIMEOUT_MS = core.MAX_LOCATIONS, core.ATTACH_TIMEOUT_MS


local function symbol_kind(kind)
    return vim.lsp.protocol.SymbolKind[kind] or tostring(kind)
end

-- DocumentSymbol[] (hierarchical) or SymbolInformation[] (flat) -> outline,
-- each entry carrying the declaration line so signatures are visible.
local function flatten_symbols(symbols, depth, out, bufnr)
    for _, s in ipairs(symbols or {}) do
        local range = s.selectionRange or (s.location and s.location.range)
        local lnum = range and (range.start.line + 1) or 0
        local kind = symbol_kind(s.kind)
        if kind == "Null" then
            -- clangd's wrapper for a macro-opened namespace: show what is
            -- inside it at this depth, not the macro itself.
            flatten_symbols(s.children, depth, out, bufnr)
        else
            out[#out + 1] = ("%s%d: %s %s — %s"):format(
                string.rep("  ", depth), lnum, kind, s.name,
                bufnr and lnum > 0 and decl_line(bufnr, lnum) or "")
            if s.children then
                flatten_symbols(s.children, depth + 1, out, bufnr)
            end
        end
    end
    return out
end

-- Treesitter skim: every declaration-shaped node's first line, nested.
-- Fast, needs no language server, works on any file with a parser.
local MAX_SKIM_FILES = 20

local MAX_SKIM_ENTRIES = 150

-- Node types are matched on their underscore-separated segments, exactly:
-- "function_declaration" has segment "function" (wanted), while
-- "table_constructor" does not have segment "struct", and
-- "method_index_expression" is rejected by its "index"/"expression" segments.
local TS_WANTED = {
    ["function"] = true, method = true, class = true, struct = true,
    interface = true, impl = true, module = true, enum = true, trait = true,
}

local TS_EXCLUDED = {
    call = true, parameter = true, parameters = true, argument = true,
    arguments = true, index = true, expression = true, pointer = true,
    import = true, type = true, body = true,
    -- TypeScript's "extends Base" clause is a class_heritage node: it
    -- carries the class name again without declaring anything.
    heritage = true,
}

-- Whole node types wanted despite an excluded segment: JavaScript's
-- "const f = function () {}" is a function_expression; Go's structs and
-- interfaces live under type_declaration; TypeScript's "type X = ..." is a
-- type_alias_declaration; Rust's "type"/"mod" items are declarations too.
local TS_WANTED_EXACT = {
    function_expression = true,
    type_declaration = true,
    type_alias_declaration = true,
    type_item = true,
    mod_item = true,
    -- Markdown's grammar nests a "section" per heading, so a document's
    -- headings index like declarations: "Install/Requirements" is a name
    -- path, and a section is a body. INI files use the same node name.
    section = true,
}

-- True for node types the workspace map must not descend into: call
-- arguments hold callbacks ("describe(..., () => {})", "$constructor(name,
-- (inst, def) => {})") that are not declarations of the file.
local function ts_opaque(node_type)
    for segment in node_type:gmatch("[^_]+") do
        if segment == "call" or segment == "arguments" or segment == "argument" then
            return true
        end
    end
    return false
end

-- Declarations that hold other declarations, as opposed to a function whose
-- body is statements. The workspace map descends into these one level.
local TS_CONTAINER = {
    class = true,
    struct = true,
    interface = true,
    impl = true,
    module = true,
    trait = true,
    enum = true,
    section = true,
}

local function ts_container(node_type)
    local container = false
    for segment in node_type:gmatch("[^_]+") do
        if segment == "function" or segment == "method" then
            return false
        end
        if TS_CONTAINER[segment] then
            container = true
        end
    end
    return container
end

local function ts_wanted(node_type)
    if TS_WANTED_EXACT[node_type] then
        return true
    end
    local wanted = false
    for segment in node_type:gmatch("[^_]+") do
        if TS_EXCLUDED[segment] then
            return false
        end
        if TS_WANTED[segment] then
            wanted = true
        end
    end
    return wanted
end

local function ts_outline(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function()
        return parser:parse()
    end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local out = {}
    local last_row = -1
    local extra, extra_last_row = 0, -1
    local function walk(node, depth)
        for child in node:iter_children() do
            if child:named() then
                if ts_wanted(child:type()) then
                    local srow, _, erow = child:range()
                    -- A wrapper and its inner node often start on the same
                    -- row (e.g. declaration + definition); emit it once.
                    if #out >= MAX_SKIM_ENTRIES then
                        -- Past the cap, keep counting top-level-ish entries
                        -- so the tail note can say what was left out.
                        if srow ~= extra_last_row and depth <= 1 then
                            extra_last_row = srow
                            extra = extra + 1
                        end
                    elseif srow ~= last_row then
                        last_row = srow
                        local span = erow > srow
                            and ("%d-%d"):format(srow + 1, erow + 1)
                            or tostring(srow + 1)
                        out[#out + 1] = ("%s%s: %s"):format(
                            string.rep("  ", depth), span, decl_line(bufnr, srow + 1))
                    end
                    if #out < MAX_SKIM_ENTRIES or depth < 1 then
                        walk(child, depth + 1)
                    end
                else
                    walk(child, depth)
                end
            end
        end
    end
    walk(trees[1]:root(), 0)
    if extra > 0 then
        local last_line = tonumber(out[#out]:match("^%s*(%d+)")) or 0
        out[#out + 1] = ("… +%d more declarations after line %d; find_symbol or "
            .. "read_file with offset reach them"):format(extra, last_line)
    end
    return out
end

-- Structural multi-file search: run a treesitter query over a set of files.
local MAX_QUERY_FILES = 50

local MAX_QUERY_MATCHES = 200

local function ts_query(args)
    local qstr = args.query
    if type(qstr) ~= "string" or qstr == "" then
        err("missing required argument: query (a treesitter s-expression query)")
    end
    local files = {}
    for _, f in ipairs(args.files or {}) do
        files[#files + 1] = f
    end
    local glob_note
    if type(args.glob) == "string" and args.glob ~= "" then
        local paths, why = expand_glob(args.root, args.glob)
        glob_note = why
        vim.list_extend(files, paths)
    end
    if #files == 0 then
        err("%s", glob_note or "no files to search: pass files (array of paths) and/or glob")
    end
    if #files > MAX_QUERY_FILES then
        files = vim.list_slice(files, 1, MAX_QUERY_FILES)
    end

    local compiled, first_query_error = {}, nil
    local matches, skipped = {}, {}
    for _, f in ipairs(files) do
        if #matches >= MAX_QUERY_MATCHES then
            break
        end
        local okb, bufnr = pcall(load_buf, f)
        if not okb then
            skipped[#skipped + 1] = f .. " (unreadable)"
        else
            local okp, parser = pcall(vim.treesitter.get_parser, bufnr)
            if not (okp and parser) then
                skipped[#skipped + 1] = f .. " (no treesitter parser)"
            else
                local lang = parser:lang()
                if compiled[lang] == nil then
                    local okq, q = pcall(vim.treesitter.query.parse, lang, qstr)
                    if okq then
                        compiled[lang] = q
                    else
                        compiled[lang] = false
                        first_query_error = first_query_error
                            or ("for language %s: %s"):format(lang, tostring(q))
                    end
                end
                local q = compiled[lang]
                local tree = q and parser:parse()[1] or nil
                if tree then
                    for id, node in q:iter_captures(tree:root(), bufnr) do
                        if #matches >= MAX_QUERY_MATCHES then
                            break
                        end
                        local srow = node:range()
                        local text = vim.treesitter.get_node_text(node, bufnr)
                            :gsub("%s+", " ")
                        if #text > 120 then
                            text = text:sub(1, 120) .. "…"
                        end
                        matches[#matches + 1] = {
                            file = vim.api.nvim_buf_get_name(bufnr),
                            line = srow + 1,
                            capture = q.captures[id],
                            text = text,
                        }
                    end
                end
            end
        end
    end
    if #matches == 0 and first_query_error then
        err("the query does not compile %s. Check node type names against the "
            .. "grammar - the skim tool shows which constructs exist in a file.",
            first_query_error:gsub("\n", " "))
    end
    local res = { count = #matches, matches = matches }
    if #skipped > 0 then
        res.skipped = skipped
    end
    if #matches >= MAX_QUERY_MATCHES then
        res.note = ("truncated at %d matches"):format(MAX_QUERY_MATCHES)
    end
    return res
end

-- Filetypes whose treesitter outline is unreliable when a server is up.
local PREFER_LSP_OUTLINE = { c = true, cpp = true, objc = true, objcpp = true, cuda = true }

local function skim(args)
    local files = args.files
    if type(files) ~= "table" or #files == 0 then
        err("missing required argument: files (array of paths)")
    end
    if #files > MAX_SKIM_FILES then
        err("too many files: %d (max %d)", #files, MAX_SKIM_FILES)
    end
    local out = {}
    for _, f in ipairs(files) do
        local okb, bufnr = pcall(load_buf, f)
        if not okb then
            out[#out + 1] = { file = f, error = tostring(bufnr) }
        else
            local entry = {
                file = vim.api.nvim_buf_get_name(bufnr),
                total_lines = vim.api.nvim_buf_line_count(bufnr),
            }
            local function lsp_outline(timeout_ms)
                local okc, client = pcall(get_client, bufnr,
                    "textDocument/documentSymbol", timeout_ms)
                if not okc then return nil end
                local okr, syms = pcall(request, client, bufnr,
                    "textDocument/documentSymbol",
                    { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
                if not okr then return nil end
                local flat = flatten_symbols(syms, 0, {}, bufnr)
                return #flat > 0 and flat or nil
            end
            local outline
            if PREFER_LSP_OUTLINE[vim.bo[bufnr].filetype] then
                -- Macro-heavy C and C++ confuse the treesitter grammar
                -- (FMT_BEGIN_NAMESPACE swallowing a file, expressions read
                -- as declarators); the language server's symbols are exact.
                outline = lsp_outline(3000)
            end
            outline = outline or ts_outline(bufnr)
            if not (outline and #outline > 0) then
                -- No parser (or nothing recognized): try LSP symbols, briefly.
                outline = lsp_outline(1500)
            end
            if outline and #outline > 0 then
                entry.outline = outline
            else
                local ft = vim.bo[bufnr].filetype
                if ft ~= "" and not has_parser(ft)
                    and #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
                    entry.note = ("no treesitter parser and no language server for %s: "
                        .. "no outline; read the file instead"):format(ft)
                else
                    entry.note = "no outline available for this file; read it instead"
                end
            end
            out[#out + 1] = entry
        end
    end
    return { files = out }
end

-- Workspace map: the whole repo's shape in one cheap call - every project
-- file with its line count and TOP-LEVEL declarations only. Parses straight
-- from disk with string parsers, so no buffers are created and no language
-- servers attach; files without a parser are listed with name and size only.
local MAX_MAP_FILES = 200

-- Up to this many files, tests are part of the map by default.
local MAP_SMALL_PROJECT = 40

local MAX_MAP_ENTRIES = 250

local MAP_TEXT_MAX = 80

-- Per-file share of the outline budget, so one file with hundreds of
-- declarations cannot blank out the rest of the map.
local MAP_FILE_MIN = 8

local MAP_FILE_MAX = 60

-- How far into a container declaration the map goes. One level turns
-- "class Flask(App):" into that class and its methods; deeper is skim's job.
local MAP_MAX_DEPTH = 1

local MAX_MAP_FILE_BYTES = 2 * 1024 * 1024

-- Filetypes seen by workspace_map that have no treesitter parser: reported
-- once per call so the client knows why outlines are missing.
local function top_level_outline(path, budget, missing)
    -- Returns outline (or nil), line count, and a skip reason for files that
    -- are not source text.
    if vim.fn.getfsize(path) > MAX_MAP_FILE_BYTES then
        return nil, nil, "large"
    end
    -- readfile() maps NUL bytes to newlines, so sniff the raw head instead.
    local fh = io.open(path, "rb")
    if fh then
        local head = fh:read(4096)
        fh:close()
        if head and head:find("%z") then
            return nil, nil, "binary"
        end
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if not ok or #lines == 0 then
        return nil, 0
    end
    local ft = vim.filetype.match({ filename = path, contents = lines })
    if not ft then
        return nil, #lines
    end
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local okp, parser = pcall(vim.treesitter.get_string_parser,
        table.concat(lines, "\n"), lang)
    if not okp or not parser then
        if missing and not DATA_FILETYPES[ft] then
            missing[ft] = (missing[ft] or 0) + 1
        end
        return nil, #lines
    end
    local okt, trees = pcall(function() return parser:parse() end)
    if not okt or not trees or not trees[1] then
        return nil, #lines
    end
    local out, extra = {}, 0
    -- Emit declaration-shaped nodes, descending one level into the ones that
    -- hold other declarations. Stopping at the top level suits Go, where
    -- methods are top-level anyway, but it reduces a 1600-line Python module
    -- to "class Flask(App):" - true, and no use to anyone. One level in, a
    -- class lists its methods and the map is worth reading again. Past the
    -- budget, keep counting so the entry can say how much was left out.
    local function walk(node, depth)
        for child in node:iter_children() do
            if child:named() then
                local ctype = child:type()
                if ts_wanted(ctype) then
                    if #out >= budget then
                        extra = extra + 1
                    else
                        local srow = child:range()
                        local text = (lines[srow + 1] or ""):gsub("^%s+", "")
                        if #text > MAP_TEXT_MAX then
                            text = text:sub(1, MAP_TEXT_MAX) .. "…"
                        end
                        out[#out + 1] = ("%s%d: %s"):format(("  "):rep(depth), srow + 1, text)
                    end
                    if depth < MAP_MAX_DEPTH and ts_container(ctype) then
                        walk(child, depth + 1)
                    end
                elseif not ts_opaque(ctype) then
                    walk(child, depth)
                end
            end
        end
    end
    walk(trees[1]:root(), 0)
    if extra > 0 then
        out[#out + 1] = ("… +%d more declarations (skim the file for all of them)"):format(extra)
    end
    return out, #lines
end

local function workspace_map(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        err("missing project root")
    end
    local target = root
    if type(args.path) == "string" and args.path ~= "" then
        target = args.path:sub(1, 1) == "/" and args.path or (root .. "/" .. args.path)
    end
    local files = vim.fn.systemlist({ "git", "-C", target,
        "ls-files", "--cached", "--others", "--exclude-standard" })
    if vim.v.shell_error ~= 0 then
        files = {}
        for _, f in ipairs(vim.fn.globpath(target, "**/*", true, true)) do
            if vim.fn.isdirectory(f) == 0 then
                files[#files + 1] = f:sub(#target + 2)
            end
        end
    end
    -- git lists tracked files before untracked ones; a path-sorted map is
    -- easier to scan and stable across runs.
    table.sort(files)
    local tests_skipped = 0
    -- Tests are left out to keep a big map readable; in a small project
    -- they are the spec (a bug-fix task starts from the failing test) and
    -- the map has room for them, so they stay in unless asked otherwise.
    local include_tests = args.include_tests
    if include_tests == nil then
        include_tests = #files <= MAP_SMALL_PROJECT
    end
    if not include_tests then
        files = vim.tbl_filter(function(f)
            if is_test_path(f) then
                tests_skipped = tests_skipped + 1
                return false
            end
            return true
        end, files)
    end
    local glob_note
    if type(args.glob) == "string" and args.glob ~= "" then
        -- Same feel as ripgrep's -g: a bare "*.go" matches at any depth,
        -- "**/*.go" also matches files in the root itself, and "bridge/**/*.go"
        -- matches bridge/x.go as well as bridge/sub/x.go ("**" spans zero
        -- directories too, which glob2regpat's ".*" needs a hand with).
        local re = vim.regex(vim.fn.glob2regpat(args.glob))
        local zero = vim.regex(vim.fn.glob2regpat((args.glob:gsub("/%*%*/", "/"))))
        local anywhere = not args.glob:find("/", 1, true)
        local before_glob = #files
        files = vim.tbl_filter(function(f)
            local probe = anywhere and vim.fs.basename(f) or f
            return re:match_str(probe) ~= nil or re:match_str("/" .. f) ~= nil
                or zero:match_str(probe) ~= nil
        end, files)
        if #files == 0 and before_glob > 0 then
            glob_note = ("0 of %d files matched the glob %q; it is matched against the path "
                .. "from the root (\"**\" spans directories, \"*.go\" alone matches at any depth), "
                .. "and path= narrows by directory instead"):format(before_glob, args.glob)
        end
    end
    local total_files = #files
    local out, entries = {}, 0
    local missing, skipped = {}, 0
    for i, rel in ipairs(files) do
        if i > MAX_MAP_FILES then
            break
        end
        if i % 10 == 0 then
            sleep(0) -- yield so the editor stays responsive on big repos
        end
        local entry = { file = rel }
        local outline, nlines, skip = top_level_outline(target .. "/" .. rel,
            MAP_FILE_MAX, missing)
        if skip then
            entry.skipped = skip
            skipped = skipped + 1
        else
            entry.lines = nlines
        end
        if outline and #outline > 0 then
            entry.outline = outline
        end
        out[#out + 1] = entry
    end
    -- Share the outline budget: files with few declarations keep them all,
    -- the rest split what is left evenly (smallest first, so nothing is
    -- cut that would have fit), ending with a "+N more" line.
    local order, cut_files = {}, 0
    for i, entry in ipairs(out) do
        if entry.outline then order[#order + 1] = i end
    end
    table.sort(order, function(a, b) return #out[a].outline < #out[b].outline end)
    for k, i in ipairs(order) do
        local outline = out[i].outline
        local share = math.floor((MAX_MAP_ENTRIES - entries) / (#order - k + 1))
        local keep = math.max(MAP_FILE_MIN, share)
        if #outline > keep then
            local last = outline[#outline]
            local extra = #outline - keep
            local more = last:match("^… %+(%d+) more") -- fold a cap line from the parse
            if more then extra = extra + tonumber(more) - 1 end
            local cut = { unpack(outline, 1, keep) }
            cut[#cut + 1] = ("… +%d more declarations (skim the file for all of them)"):format(extra)
            out[i].outline = cut
            cut_files = cut_files + 1
            entries = entries + keep + 1
        else
            entries = entries + #outline
        end
    end
    local notes = {}
    if glob_note then
        notes[#notes + 1] = glob_note
    end
    if total_files > MAX_MAP_FILES then
        notes[#notes + 1] = ("showing first %d of %d files; narrow with path or glob")
            :format(MAX_MAP_FILES, total_files)
    elseif cut_files > 0 then
        notes[#notes + 1] = ("%d outlines were shortened to fit the map (\"+N more\" lines); "
            .. "skim those files for the full list"):format(cut_files)
    end
    if tests_skipped > 0 then
        notes[#notes + 1] = ("%d test files left out; include_tests=true lists them"):format(tests_skipped)
    end
    if next(missing) then
        local parts = {}
        for ft, n in pairs(missing) do
            parts[#parts + 1] = ("%s (%d files)"):format(ft, n)
        end
        table.sort(parts)
        notes[#notes + 1] = "no treesitter parser installed for: " .. table.concat(parts, ", ")
            .. "; those files are listed without outlines (skim/find_symbol/ts_query"
            .. " are blind to them too - grep and read_file still work)"
    end
    if skipped > 0 then
        notes[#notes + 1] = ("%d binary or oversized files skipped"):format(skipped)
    end
    return {
        file_count = total_files,
        files = out,
        note = #notes > 0 and table.concat(notes, ". ") or nil,
    }
end

local function document_symbols(args)
    local bufnr = load_buf(args.file)
    local client = get_client(bufnr, "textDocument/documentSymbol")
    local result = request(client, bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
    return { outline = flatten_symbols(result, 0, {}, bufnr) }
end

-- Servers such as lua_ls answer workspace/symbol with everything in their
-- library path (the Neovim runtime, every plugin) and rank loosely, so the
-- project's own symbols drown. Keep in-project hits first, ranked by how
-- literally the name matches, and only a handful from outside the root.
local MAX_EXTERNAL_SYMBOLS = 10

local function symbol_match_rank(name, query)
    local n, q = name:lower(), query:lower()
    local last = n:match("([^%.:/]+)$") or n
    if last == q or n == q then
        return 1
    end
    if last:find(q, 1, true) then
        return 2
    end
    if n:find(q, 1, true) then
        return 3
    end
    return 4
end

-- Open the most central source file of each language a server is running
-- for, so the server has the project's real configuration in view. Returns
-- true when something new was opened and it is worth asking again. Done at
-- most once per root: the buffers stay loaded afterwards.
local warmed_roots = {}

local function warm_up_project(root)
    if warmed_roots[root] then
        return false
    end
    warmed_roots[root] = true
    local served = {}
    for _, client in ipairs(vim.lsp.get_clients()) do
        for _, ft in ipairs(client.config and client.config.filetypes or {}) do
            served[ft] = true
        end
    end
    if not next(served) then
        return false
    end
    local sample, ext_cache = {}, {}
    for _, rel in ipairs(project_files(root)) do
        local ext = rel:match("%.([%w_]+)$") or rel
        local ft = ext_cache[ext]
        if ft == nil then
            ft = vim.filetype.match({ filename = rel }) or false
            ext_cache[ext] = ft
        end
        if ft and served[ft] and better_sample(sample[ft], rel) then
            sample[ft] = rel
        end
    end
    local opened = false
    for _, rel in pairs(sample) do
        if pcall(load_buf, root .. "/" .. rel) then
            opened = true
        end
    end
    if opened then
        sleep(FRESH_RETRY_MS)
    end
    return opened
end

-- Defined below workspace_symbols, which calls it: a forward declaration
-- rather than a global.
local fallback_symbol_search

local function workspace_symbols(args)
    local query = args.query
    if type(query) ~= "string" then
        err("missing required argument: query")
    end
    local root = type(args.root) == "string" and args.root ~= "" and args.root or nil
    local function in_root(file)
        if not root or not file then
            return false
        end
        return file == root or file:sub(1, #root + 1) == root .. "/"
    end
    local inside, outside, seen_client, warming
    local function collect()
        inside, outside, seen_client, warming = {}, {}, false, false
        for _, client in ipairs(vim.lsp.get_clients()) do
            if client:supports_method("workspace/symbol") then
                local bufnr = next(client.attached_buffers or {})
                if bufnr then
                    seen_client = true
                    if fresh_buf(bufnr) then warming = true end
                    local result = request(client, bufnr, "workspace/symbol", { query = query })
                    for _, s in ipairs(result or {}) do
                        local loc = s.location or {}
                        local file = loc.uri and vim.uri_to_fname(loc.uri) or nil
                        local item = {
                            name = s.name,
                            kind = symbol_kind(s.kind),
                            file = file,
                            line = loc.range and (loc.range.start.line + 1) or nil,
                            container = s.containerName,
                            server = client.name,
                            rank = symbol_match_rank(s.name or "", query),
                        }
                        if in_root(file) or not root then
                            inside[#inside + 1] = item
                        else
                            outside[#outside + 1] = item
                        end
                    end
                end
            end
        end
    end
    collect()
    -- An empty list is the same answer as "that symbol does not exist", so
    -- before believing it, rule out the two ways a server can be answering
    -- about less than the whole project: it may still be indexing, or it
    -- may never have been shown a file central enough to work out what the
    -- project is (tsserver builds its program from the files it is given,
    -- so one bench script gets you a one-file program).
    if #inside == 0 and warming then
        sleep(FRESH_RETRY_MS)
        collect()
    end
    local from_files
    if #inside == 0 and root then
        if warm_up_project(root) then
            collect()
        end
        if #inside == 0 then
            from_files = fallback_symbol_search(root, query)
        end
    end
    if not seen_client then
        err("no active LSP client supports workspace/symbol; open a file of "
            .. "that language first (find_symbol, read_file) so its server starts")
    end
    local function by_rank(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return (a.name or "") < (b.name or "")
    end
    table.sort(inside, by_rank)
    table.sort(outside, by_rank)
    local out = {}
    for i, item in ipairs(inside) do
        if i > MAX_LOCATIONS then break end
        item.rank = nil
        out[#out + 1] = item
    end
    -- Library and runtime hits are only worth their tokens when the project
    -- itself has nothing to offer. Asking for a project symbol and getting
    -- ten results from go/pkg/mod under the four real ones is noise.
    local external = 0
    if #inside == 0 then
        for _, item in ipairs(outside) do
            if #out >= MAX_LOCATIONS or external >= MAX_EXTERNAL_SYMBOLS then break end
            item.rank = nil
            item.external = true
            out[#out + 1] = item
            external = external + 1
        end
    end
    local note
    if #outside > external then
        note = ("%d matches outside the project (libraries, runtime) not listed")
            :format(#outside - external)
    end
    local project_matches = #inside
    if #inside == 0 and from_files and #from_files > 0 then
        for i, item in ipairs(from_files) do
            if i > MAX_LOCATIONS then break end
            table.insert(out, i, item)
        end
        project_matches = math.min(#from_files, MAX_LOCATIONS)
        note = "found by reading the project's files: the language server's "
            .. "index did not have them (it covers the files it has been shown)"
            .. (note and ("; " .. note) or "")
    elseif #inside == 0 and root then
        note = "no match inside the project (find_symbol and grep search the "
            .. "files directly and do not depend on the server's index)"
            .. (note and ("; " .. note) or "")
    end
    return { count = #out, project_matches = project_matches, symbols = out, note = note }
end

local index_cache = {}

-- A Markdown section is named by its heading, without the markers: the
-- "## Install" line of an ATX heading, or the text line of a setext one.
local function section_name(node, bufnr)
    for child in node:iter_children() do
        if child:type():find("heading$") then
            local text = vim.treesitter.get_node_text(child, bufnr)
            local first = text:match("^[^\n]*") or text
            first = first:gsub("^%s*#+%s*", ""):gsub("%s*#+%s*$", "")
            first = vim.trim(first)
            if first ~= "" then return first end
        end
    end
    return nil
end

local function ts_node_name(node, bufnr)
    if node:type() == "section" then
        local heading = section_name(node, bufnr)
        if heading then return heading end
    end
    local name_field = node:field("name")
    if name_field and name_field[1] then
        local name = vim.treesitter.get_node_text(name_field[1], bufnr)
        -- Go methods: qualify by receiver type so "jsonBinding/Bind" and
        -- "xmlBinding/Bind" stay distinct (a suffix match on "Bind" still
        -- finds both).
        local recv = node:field("receiver")
        if recv and recv[1] then
            local text = vim.treesitter.get_node_text(recv[1], bufnr):gsub("%[.-%]", "")
            local rtype = text:match("([%w_]+)%s*%)?%s*$") or text:match("%*?([%w_]+)")
            if rtype and rtype ~= "" then
                return rtype .. "/" .. name
            end
        end
        return name
    end
    -- Declarations that wrap the named node (Go type_declaration holding a
    -- type_spec): take the first child that carries a name.
    for child in node:iter_children() do
        local cname = child:field("name")
        if cname and cname[1] then
            return vim.treesitter.get_node_text(cname[1], bufnr)
        end
    end
    -- Anonymous functions take the name of the declaration they sit in:
    -- "const Zod = $constructor('Zod', (inst, def) => {" is Zod, a Lua
    -- table field "hover = function(args)" is hover. Stay on the same
    -- line so a callback deep inside a body is not named after it.
    local srow = node:range()
    local parent = node:parent()
    for _ = 1, 4 do
        if not parent then break end
        local prow = parent:range()
        if prow ~= srow then break end
        local pname = parent:field("name")
        if pname and pname[1] then
            return vim.treesitter.get_node_text(pname[1], bufnr)
        end
        parent = parent:parent()
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1] or ""
    -- A function assigned to a name ("references = function(args)",
    -- "M.x = function", "const shout = (name) => ...") is named by the
    -- left-hand side; only then fall back to the first "ident(" on the
    -- line, which for those forms would be "function" or the first callee.
    return line:match("([%w_.:$]+)%s*=%s*function%s*[%(<]")
        or line:match("([%w_.:$]+)%s*=%s*async%s*function%s*[%(<]")
        or line:match("([%w_.:$]+)%s*=%s*async%s*%(")
        or line:match("([%w_.:$]+)%s*=%s*%(")
        or line:match("([%w_.:$]+)%s*%(") or line:match("([%w_.:$]+)%s*[={:]")
        or ("line" .. (srow + 1))
end

local function ts_index(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local entries = {}
    local function walk(node, prefix)
        for child in node:iter_children() do
            if child:named() then
                if ts_wanted(child:type()) then
                    local srow, _, erow, ecol = child:range()
                    -- A node ending at column 0 stopped at the previous
                    -- line's newline (a Markdown section runs up to the
                    -- next heading): its last line is the one before.
                    if ecol == 0 and erow > srow then
                        erow = erow - 1
                    end
                    local name = ts_node_name(child, bufnr)
                    local path = prefix == "" and name or (prefix .. "/" .. name)
                    entries[#entries + 1] = {
                        path = path, name = name, kind = child:type(),
                        first = srow + 1, last = erow + 1,
                    }
                    walk(child, path)
                else
                    walk(child, prefix)
                end
            end
        end
    end
    walk(trees[1]:root(), "")
    return entries
end

local function lsp_index(bufnr)
    local okc, client = pcall(get_client, bufnr, "textDocument/documentSymbol", 2000)
    if not okc then
        return nil
    end
    local okr, syms = pcall(request, client, bufnr, "textDocument/documentSymbol",
        { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
    if not okr then
        return nil
    end
    local entries = {}
    local function walk(list, prefix)
        for _, s in ipairs(list or {}) do
            local range = s.range or (s.location and s.location.range)
            local kind = symbol_kind(s.kind)
            if range and kind == "Null" then
                -- clangd wraps a macro-opened namespace (FMT_BEGIN_NAMESPACE)
                -- in a Null symbol: not a name anyone addresses, skip it.
                walk(s.children, prefix)
            elseif range then
                local path = prefix == "" and s.name or (prefix .. "/" .. s.name)
                entries[#entries + 1] = {
                    path = path, name = s.name, kind = kind,
                    first = range.start.line + 1, last = range["end"].line + 1,
                }
                walk(s.children, path)
            end
        end
    end
    walk(syms, "")
    return entries
end

-- The treesitter index deliberately only keeps declarations that carry a
-- body - functions, classes, types. That leaves out the named constants and
-- module-level variables an agent does have to find and edit: Go's MIME
-- string table, a TypeScript exported regex, a Python module default. The
-- language server lists those in its document symbols, so fold in the ones
-- treesitter had no node for.
--
-- Returns the entries and whether the server actually answered, so that a
-- result assembled without it is not cached as if it were complete.
local function merge_lsp_only_symbols(entries, bufnr)
    if #enabled_lsp_configs_for(vim.bo[bufnr].filetype) == 0 then
        return entries, true -- nothing will ever attach; this is as good as it gets
    end
    if not pcall(get_client, bufnr, "textDocument/documentSymbol", ATTACH_TIMEOUT_MS) then
        return entries, false
    end
    local from_lsp = lsp_index(bufnr)
    if not from_lsp or #from_lsp == 0 then
        return entries, false
    end
    local covered = {}
    for _, e in ipairs(entries) do
        covered[e.name] = true
    end
    for _, e in ipairs(from_lsp) do
        if not covered[e.name] then
            entries[#entries + 1] = e
            covered[e.name] = true
        end
    end
    table.sort(entries, function(a, b)
        if a.first ~= b.first then return a.first < b.first end
        return (a.path or "") < (b.path or "")
    end)
    return entries, true
end

local function symbol_index(bufnr)
    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local cached = index_cache[bufnr]
    if cached and cached.tick == tick and cached.complete then
        return cached.entries
    end
    local entries, complete
    if PREFER_LSP_OUTLINE[vim.bo[bufnr].filetype] then
        -- Same reasoning as skim: clangd's symbols beat the C/C++ grammar.
        entries = lsp_index(bufnr)
        complete = entries ~= nil and #entries > 0
    end
    if not entries or #entries == 0 then
        entries = ts_index(bufnr)
        if entries and #entries > 0 then
            entries, complete = merge_lsp_only_symbols(entries, bufnr)
        end
    end
    if not entries or #entries == 0 then
        entries = lsp_index(bufnr) or {}
        complete = #entries > 0
    end
    index_cache[bufnr] = { tick = tick, entries = entries, complete = complete }
    return entries
end

-- Rank: 1 exact path, 2 path suffix / exact name, 3 name substring.
-- Language servers may name a symbol with its signature ("main(String[])",
-- "accumulate(List<Integer>) : int" from jdtls); a name path written
-- without one still has to find it.
local function strip_signature(s)
    return (s:gsub("%b()", ""):gsub("%s*:%s*[^/]*$", ""):gsub("%s+$", ""))
end

local function match_rank(entry, name)
    if entry.path == name then
        return 1
    end
    local n = #name
    if #entry.path > n and entry.path:sub(-n) == name
        and entry.path:sub(-n - 1, -n - 1) == "/" then
        return 2
    end
    if entry.name == name then
        return 2
    end
    if not name:find("(", 1, true) and entry.name:find("(", 1, true) then
        local bare_path = strip_signature(entry.path)
        if bare_path == name then
            return 1
        end
        if #bare_path > n and bare_path:sub(-n) == name
            and bare_path:sub(-n - 1, -n - 1) == "/" then
            return 2
        end
        if strip_signature(entry.name) == name then
            return 2
        end
    end
    if entry.name:lower():find(name:lower(), 1, true) then
        return 3
    end
    return nil
end

local MAX_FIND_RESULTS = 20

local MAX_BODY_LINES = 200

-- Body lines are numbered RELATIVE to the symbol (declaration = 1), matching
-- the addressing of replace_symbol_lines; the absolute file range is in the
-- accompanying `lines` field.
-- Search the project's own files for a symbol, without asking a server.
--
-- Some servers only index the files they have been handed - tsserver builds
-- its program from open files, so workspace/symbol in a large repository
-- answers about a fraction of it and reports the rest as "no match", which
-- is indistinguishable from the symbol not existing. Grep for the name to
-- find candidate files, then read their real symbol index, so the answer is
-- about the project rather than about what the server happens to know.
local FALLBACK_MAX_FILES = 25

function fallback_symbol_search(root, query)
    if vim.fn.executable("rg") == 0 then
        return {}
    end
    local files = vim.fn.systemlist({
        "rg", "--files-with-matches", "--fixed-strings", "--max-count", "1",
        "--sort", "path", "--", query, root,
    })
    if vim.v.shell_error > 1 then
        return {}
    end
    local found = {}
    for i, path in ipairs(files) do
        if i > FALLBACK_MAX_FILES then break end
        local okb, bufnr = pcall(load_buf, path)
        if okb then
            for _, entry in ipairs(symbol_index(bufnr)) do
                if match_rank(entry, query) then
                    found[#found + 1] = {
                        name = entry.name,
                        kind = entry.kind,
                        file = rel_path(path),
                        line = entry.first,
                        container = entry.path ~= entry.name and entry.path or nil,
                        server = "agent99 (project files)",
                        rank = symbol_match_rank(entry.name or "", query),
                    }
                end
            end
        end
    end
    table.sort(found, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return (a.name or "") < (b.name or "")
    end)
    for _, item in ipairs(found) do item.rank = nil end
    return found
end

local function symbol_body(bufnr, entry)
    local last = math.min(entry.last, entry.first + MAX_BODY_LINES - 1)
    local lines = vim.api.nvim_buf_get_lines(bufnr, entry.first - 1, last, false)
    local numbered = {}
    for i, l in ipairs(lines) do
        numbered[i] = ("%d: %s"):format(i, l)
    end
    if last < entry.last then
        numbered[#numbered + 1] = ("... (truncated; the symbol has %d lines)")
            :format(entry.last - entry.first + 1)
    end
    return numbered
end

local function find_symbol(args)
    local name = args.name
    if type(name) ~= "string" or name == "" then
        err("missing required argument: name")
    end
    local files = {}
    if type(args.file) == "string" and args.file ~= "" then
        files[#files + 1] = args.file
    end
    for _, f in ipairs(args.files or {}) do
        files[#files + 1] = f
    end
    local glob_note
    if type(args.glob) == "string" and args.glob ~= "" then
        local paths, why = expand_glob(args.root, args.glob)
        glob_note = why
        vim.list_extend(files, paths)
    end
    if #files == 0 then
        err("%s", glob_note or "no files to search: pass file, files, or glob")
    end
    if #files > MAX_QUERY_FILES then
        files = vim.list_slice(files, 1, MAX_QUERY_FILES)
    end
    local found = {}
    local function collect(query)
        for _, f in ipairs(files) do
            local okb, bufnr = pcall(load_buf, f)
            if okb then
                for _, entry in ipairs(symbol_index(bufnr)) do
                    local rank = match_rank(entry, query)
                    if rank then
                        found[#found + 1] = { rank = rank, bufnr = bufnr, entry = entry }
                    end
                end
            end
        end
    end
    collect(name)
    -- A name path ("Flask/route") is a precise question. When nothing has
    -- that path, the matches for its last segment are offered as
    -- suggestions, never as the answer: a fuzzy hit under `matches` reads
    -- exactly like the symbol being found somewhere else.
    local suggestions
    local leaf = name:match("([^/]+)$")
    if #found == 0 and leaf and leaf ~= name then
        collect(leaf)
        if #found > 0 then
            suggestions = {}
            for _, m in ipairs(found) do
                if #suggestions >= 5 then break end
                suggestions[#suggestions + 1] = {
                    name_path = m.entry.path,
                    file = rel_path(vim.api.nvim_buf_get_name(m.bufnr)),
                    lines = ("%d-%d"):format(m.entry.first, m.entry.last),
                }
            end
            local total = #found
            found = {}
            return {
                count = 0,
                matches = {},
                suggestions = suggestions,
                note = ("no symbol at path %s; %d symbols match %s, the closest listed under "
                    .. "suggestions - call again with one of those name paths"):format(name, total, leaf),
            }
        end
    end
    -- Within a rank, shorter names first (the closest to what was asked),
    -- then by file for a stable order; table.sort alone is not stable.
    for _, m in ipairs(found) do
        m.file = vim.api.nvim_buf_get_name(m.bufnr)
        m.test = is_test_path(m.file)
    end
    table.sort(found, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if (a.test ~= nil) ~= (b.test ~= nil) then return a.test == nil end
        if #a.entry.name ~= #b.entry.name then return #a.entry.name < #b.entry.name end
        if a.file ~= b.file then return a.file < b.file end
        return a.entry.first < b.entry.first
    end)
    local out = {}
    for i, m in ipairs(found) do
        if i > MAX_FIND_RESULTS then break end
        local item = {
            name_path = m.entry.path,
            kind = m.entry.kind,
            file = vim.api.nvim_buf_get_name(m.bufnr),
            lines = ("%d-%d"):format(m.entry.first, m.entry.last),
        }
        if args.include_body and (m.rank <= 2 or #found == 1) and i <= 5 then
            item.body = symbol_body(m.bufnr, m.entry)
            if i == 1 then
                pcall(function()
                    require("agent99.ui").on_read(item.file, m.entry.first)
                end)
            end
        end
        out[i] = item
    end
    local note
    if #found == 0 then
        note = "no symbol matched; try skim to see what exists"
    elseif #found > MAX_FIND_RESULTS then
        note = ("showing the best %d of %d matches; use a longer name or a name "
            .. "path (\"Type/method\") or narrow with file/glob"):format(MAX_FIND_RESULTS, #found)
    end
    return {
        count = #found,
        matches = out,
        note = note,
    }
end

-- Resolve one unambiguous symbol for an edit.
local function resolve_symbol(file, name_path)
    if type(name_path) ~= "string" or name_path == "" then
        err("missing required argument: name_path")
    end
    local bufnr = load_buf(file)
    local candidates = {}
    for _, entry in ipairs(symbol_index(bufnr)) do
        local rank = match_rank(entry, name_path)
        if rank and rank <= 2 then
            candidates[#candidates + 1] = { rank = rank, entry = entry }
        end
    end
    table.sort(candidates, function(a, b) return a.rank < b.rank end)
    if #candidates == 0 then
        err("no symbol named %q in %s; use find_symbol or skim to locate it",
            name_path, file)
    end
    if #candidates > 1 and candidates[1].rank == candidates[2].rank then
        local names = {}
        for i, c in ipairs(candidates) do
            if i > 5 then break end
            names[#names + 1] = c.entry.path
        end
        err("ambiguous symbol %q in %s: %s - use the full name path",
            name_path, file, table.concat(names, ", "))
    end
    return bufnr, candidates[1].entry
end

-- Edit a slice of a symbol, addressed by line numbers RELATIVE to the
-- symbol's first line (declaration = 1) - the numbering find_symbol bodies
-- use. Much cheaper than resending the whole symbol for a small change.
-- Where, inside the symbol, the expected text actually is. Relative line
-- numbers are read off a snapshot and drift when anything above the symbol
-- changes; the text they were meant to hit usually still exists, a few
-- lines away. Returns the relative first line of the single occurrence,
-- or nil plus how many occurrences there were.
-- The first line of the comment block sitting directly above `lnum`, or
-- lnum itself when there is none: a symbol's doc comment.
local function doc_block_start(bufnr, lnum)
    local first = lnum
    for l = lnum - 1, 1, -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local stripped = text:gsub("^%s+", "")
        if stripped:match("^%-%-") or stripped:match("^//") or stripped:match("^#")
            or stripped:match("^/%*") or stripped:match("^%*")
            or stripped:match([[^"""]]) then
            first = l
        else
            break
        end
    end
    return first
end

-- The top line of the block a declaration belongs to: its decorators or
-- attributes and the doc comment above them. A symbol's index range starts
-- at the declaration keyword, so without this an "insert before" lands
-- between a decorator and the class it annotates.
local function decl_block_top(bufnr, lnum)
    local first = lnum
    for l = lnum - 1, 1, -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local s = text:gsub("^%s+", "")
        if s:match("^@")       -- TS/JS/Java/Python decorator
            or s:match("^#%[") -- Rust attribute
            or s:match("^%-%-") or s:match("^//") or s:match("^#")
            or s:match("^/%*") or s:match("^%*") or s:match("^%*/")
            or s:match([[^"""]]) then
            first = l
        else
            break
        end
    end
    return first
end

-- First line of the contiguous comment block directly above a line, for
-- surfacing a symbol's doc summary. Language-agnostic prefix heuristic.
local function comment_above(bufnr, lnum)
    local first_comment
    for l = lnum - 1, math.max(1, lnum - 8), -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local stripped = text:gsub("^%s+", "")
        if stripped:match("^%-%-") or stripped:match("^//") or stripped:match("^#")
            or stripped:match("^/%*") or stripped:match("^%*") or stripped:match('^"""') then
            first_comment = stripped
        else
            break
        end
    end
    if first_comment and #first_comment > 90 then
        first_comment = first_comment:sub(1, 90) .. "…"
    end
    return first_comment
end

-- Control-flow nesting depth of a line inside its enclosing symbol: how many
-- loops/branches the line sits under. Segment-matched like ts_wanted.
local DEPTH_SEGMENTS = {
    ["for"] = true, ["while"] = true, ["repeat"] = true, loop = true,
    ["if"] = true, elseif_ = true, switch = true, case = true,
    match = true, try = true,
}

local function control_depth(bufnr, line, sym_first)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local node = trees[1]:root():descendant_for_range(line - 1, 0, line - 1, 0)
    local depth = 0
    while node do
        local srow = node:range()
        if srow < sym_first - 1 then
            break -- left the enclosing symbol
        end
        for segment in node:type():gmatch("[^_]+") do
            if DEPTH_SEGMENTS[segment] then
                depth = depth + 1
                break
            end
        end
        node = node:parent()
    end
    return depth
end

local function innermost_entry(entries, line)
    local best
    for _, e in ipairs(entries) do
        if e.first <= line and line <= e.last then
            if not best or (e.last - e.first) < (best.last - best.first) then
                best = e
            end
        end
    end
    return best
end

-- Classify what a hit at (line, col) actually is: the definition line of its
-- symbol, the callee of a call, or text inside a comment or string literal.
-- nil (no tag) means a plain code reference.
local function classify_hit(bufnr, line, col, entry)
    if entry and entry.first == line then
        return "def"
    end
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or parser == nil then
        return nil
    end
    local okp, trees = pcall(function() return parser:parse() end)
    if not okp or not trees or not trees[1] then
        return nil
    end
    local c = math.max((tonumber(col) or 1) - 1, 0)
    local node = trees[1]:root():descendant_for_range(line - 1, c, line - 1, c)
    if not node then
        return nil
    end
    local n = node
    while n do
        local t = n:type()
        if t:find("comment", 1, true) then
            return "comment"
        end
        if t:find("string", 1, true) then
            return "string"
        end
        n = n:parent()
    end
    n = node
    for _ = 1, 4 do
        local p = n and n:parent()
        if not p then
            break
        end
        for segment in p:type():gmatch("[^_]+") do
            if segment == "call" or segment == "invocation" then
                local callee = (p:field("function") or {})[1] or (p:field("name") or {})[1]
                if callee and (callee == node
                    or vim.treesitter.is_ancestor(callee, node)) then
                    return "call"
                end
            end
        end
        n = p
    end
    return nil
end

-- Worst diagnostic severity already present on a line (ERROR/WARN or nil).
local function line_diag(bufnr, line)
    local worst
    for _, d in ipairs(vim.diagnostic.get(bufnr, { lnum = line - 1 })) do
        if d.severity == vim.diagnostic.severity.ERROR then
            return "ERROR"
        end
        if d.severity == vim.diagnostic.severity.WARN then
            worst = "WARN"
        end
    end
    return worst
end

-- Internal (not in the model's tool list): line -> enclosing symbol info
-- (name path, declaration line = signature, doc comment summary, position,
-- nesting depth, hit kind, existing diagnostics), used by the bridge to
-- annotate grep hits. args.cols is optional, aligned with args.lines.
local function enclosing_symbols(args)
    local bufnr = load_buf(args.file)
    local entries = symbol_index(bufnr)
    local out = {}
    for i, line in ipairs(args.lines or {}) do
        local n = tonumber(line)
        local e = innermost_entry(entries, n)
        -- What the hit *is* does not depend on it being inside a symbol: a
        -- doc comment above a type, a package-level constant and a line in a
        -- script all have a kind, and a caller filtering by kind needs it for
        -- every hit. Only the symbol-relative fields require an enclosing
        -- symbol.
        local info = {
            kind = classify_hit(bufnr, n, (args.cols or {})[i], e),
            diag = line_diag(bufnr, n),
        }
        if e then
            info.path = e.path
            info.decl = decl_line(bufnr, e.first)
            info.comment = comment_above(bufnr, e.first)
            info.first = e.first
            info.pos = n - e.first + 1
            info.span = e.last - e.first + 1
            info.depth = control_depth(bufnr, n, e.first)
        end
        out[tostring(line)] = info
    end
    return { symbols = out }
end

-- Attach enclosing-symbol context to each location (used by references):
-- symbol path, position within it, nesting depth, and - once per symbol -
-- its declaration line.
local function annotate_locations(locations)
    local per_file, order = {}, {}
    for _, loc in ipairs(locations) do
        if not per_file[loc.file] then
            per_file[loc.file] = {}
            order[#order + 1] = loc.file
        end
        table.insert(per_file[loc.file], loc)
    end
    local seen = {}
    for i, file in ipairs(order) do
        if i > 10 then break end
        local okb, bufnr = pcall(load_buf, file)
        if okb then
            local entries = symbol_index(bufnr)
            for _, loc in ipairs(per_file[file]) do
                local e = innermost_entry(entries, loc.line)
                if e then
                    loc.in_symbol = e.path
                    if e.last > e.first then
                        loc.at = ("%d/%d"):format(loc.line - e.first + 1, e.last - e.first + 1)
                    end
                    local d = control_depth(bufnr, loc.line, e.first)
                    if d and d > 0 then
                        loc.depth = d
                    end
                    local key = file .. "|" .. e.path
                    if not seen[key] and e.first ~= loc.line then
                        seen[key] = true
                        loc.decl = decl_line(bufnr, e.first)
                    end
                end
            end
        end
    end
end
M.symbol_kind = symbol_kind
M.flatten_symbols = flatten_symbols
M.ts_wanted = ts_wanted
M.ts_container = ts_container
M.ts_query = ts_query
M.ts_outline = ts_outline
M.skim = skim
M.workspace_map = workspace_map
M.document_symbols = document_symbols
M.symbol_match_rank = symbol_match_rank
M.warm_up_project = warm_up_project
M.workspace_symbols = workspace_symbols
M.symbol_index = symbol_index
M.match_rank = match_rank
M.symbol_body = symbol_body
M.find_symbol = find_symbol
M.resolve_symbol = resolve_symbol
M.doc_block_start = doc_block_start
M.decl_block_top = decl_block_top
M.comment_above = comment_above
M.control_depth = control_depth
M.innermost_entry = innermost_entry
M.classify_hit = classify_hit
M.line_diag = line_diag
M.enclosing_symbols = enclosing_symbols
M.annotate_locations = annotate_locations
M.MAX_BODY_LINES = MAX_BODY_LINES

return M
