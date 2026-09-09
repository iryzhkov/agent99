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
local get_client, request = core.get_client, core.request
local has_parser, expand_glob, decl_line = core.has_parser, core.expand_glob, core.decl_line
local project_files, is_test_path, better_sample = core.project_files, core.is_test_path, core.better_sample
local fresh_buf, DATA_FILETYPES, FRESH_RETRY_MS = core.fresh_buf, core.DATA_FILETYPES, core.FRESH_RETRY_MS
local enabled_lsp_configs_for = core.enabled_lsp_configs_for
local MAX_LOCATIONS, ATTACH_TIMEOUT_MS = core.MAX_LOCATIONS, core.ATTACH_TIMEOUT_MS


local function symbol_kind(kind)
    return vim.lsp.protocol.SymbolKind[kind] or tostring(kind)
end

-- A symbol whose name is its own value rather than a name for one: the
-- elements of an array come back from some servers as one symbol each
-- ("make", "gopls", ...), so a Lua table of package names outlines as thirty
-- String entries that address nothing. One with children is kept: whatever
-- is inside it may still be worth naming.
-- A child that covers exactly the same lines as its parent adds nothing: it
-- is the same source line, one level in.
local function same_span_child(s, parent)
    if not parent then return false end
    local a = s.range or (s.location and s.location.range)
    local b = parent.range or (parent.location and parent.location.range)
    if not a or not b then return false end
    return a.start.line == b.start.line and a["end"].line == b["end"].line
end

local function value_named(s)
    if s.children and #s.children > 0 then
        return false
    end
    local name = s.name or ""
    return name:match('^".*"$') ~= nil
        or name:match("^'.*'$") ~= nil
        or name:match("^%[?%-?%d+%.?%d*%]?$") ~= nil
end

-- DocumentSymbol[] (hierarchical) or SymbolInformation[] (flat) -> outline,
-- each entry carrying the declaration line so signatures are visible.
local function flatten_symbols(symbols, depth, out, bufnr, opts)
    for _, s in ipairs(symbols or {}) do
        local range = s.selectionRange or (s.location and s.location.range)
        local lnum = range and (range.start.line + 1) or 0
        local kind = symbol_kind(s.kind)
        if kind == "Null" then
            -- clangd's wrapper for a macro-opened namespace: show what is
            -- inside it at this depth, not the macro itself.
            flatten_symbols(s.children, depth, out, bufnr, opts)
        elseif opts and opts.drop_values and same_span_child(s, opts.parent) then
            -- A child covering exactly its parent's lines is the same source
            -- line printed twice: a constant and, one level in, the callback
            -- that makes it.
            opts.dropped = (opts.dropped or 0) + 1
        elseif opts and opts.drop_values and value_named(s) then
            -- An array's elements, one symbol each and named after their own
            -- text: thirty of them are the whole outline of a data file and
            -- none of them addresses anything.
            opts.dropped = (opts.dropped or 0) + 1
        else
            out[#out + 1] = ("%s%d: %s %s — %s"):format(
                string.rep("  ", depth), lnum, kind, s.name,
                bufnr and lnum > 0 and decl_line(bufnr, lnum) or "")
            if s.children then
                local nested = opts and vim.tbl_extend("force", opts, { parent = s }) or nil
                flatten_symbols(s.children, depth + 1, out, bufnr, nested)
                if nested then opts.dropped = nested.dropped end
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
    -- A QML object holds the properties, signals and objects under it, and
    -- workspace_map descends one level into a container: without this a
    -- 1419-line component was one line of map, "20: Item {".
    ui_object_definition = true,
    struct = true,
    interface = true,
    impl = true,
    module = true,
    trait = true,
    enum = true,
    section = true,
}

-- Data files have no declarations, but they have keys: a compose file's
-- services, a TOML table, a JSON object's members, a Dockerfile's build
-- stages. Indexed per filetype, never by segment, because `pair` in a
-- JavaScript grammar is every object-literal member and would swamp the
-- index of real code.
local DATA_NODES = {
    yaml = { block_mapping_pair = true },
    json = { pair = true },
    jsonc = { pair = true },
    json5 = { pair = true },
    toml = { table = true, table_array_element = true, pair = true },
    dockerfile = { from_instruction = true },
}

-- Lists are not descended into: 450 items of "name/value" would be the
-- whole index, and a list item has no name to address it by anyway.
local DATA_OPAQUE = {
    yaml = { block_sequence = true, flow_sequence = true },
    json = { array = true },
    jsonc = { array = true },
    json5 = { array = true },
    toml = { array = true },
}

-- Two kinds of file whose declarations are not functions. A Makefile is
-- rules and the variables above them, and both are addressable: `smoke` is
-- the target and its recipe. A shell script is functions and the variables
-- it sets at the top, which is where its knobs live - "top" because an
-- assignment further in is a statement, not a declaration, and a variable
-- set again inside a loop must not index as another symbol of the file.
local FT_NODES = {
    make = { rule = true, variable_assignment = true },
    sh = { variable_assignment = "top" },
    bash = { variable_assignment = "top" },
    -- A QML file is an object tree with properties and signals on it, and
    -- the JS functions are the small part of it. Outlining only those left a
    -- 1400-line file summarised as 34 function names, with every Item,
    -- property and signal invisible.
    qml = { ui_object_definition = true, ui_property = true, ui_signal = true },
    -- A Go file whose only declaration is a const - a config sample, a MIME
    -- table - had no outline at all and so no line in the map. Only at the
    -- top level: the same node inside a function is a statement.
    go = { const_declaration = "top", var_declaration = "top" },
    rust = { const_item = "top", static_item = "top" },
}

-- A callback written as a single expression - `(store) => store.setPrompt`,
-- the shape half a React file is made of - declares nothing worth an outline
-- entry. One .tsx file of 4265 lines contributed 200 of them to a 14-file
-- skim. A callback with a statement block is a different thing (a jest
-- `describe`, an effect body) and stays.
local function expression_bodied(node)
    local t = node:type()
    if t ~= "arrow_function" and t ~= "function_expression" then
        return false
    end
    local body = node:field("body")[1]
    return body ~= nil and body:type() ~= "statement_block"
end

local function data_nodes(ft)
    return ft and DATA_NODES[ft] or nil
end

local function data_opaque(node_type, ft)
    local set = ft and DATA_OPAQUE[ft]
    return set ~= nil and set[node_type] == true
end

local function ts_container(node_type, ft)
    local data = data_nodes(ft)
    if data then
        return data[node_type] == true
    end
    -- Whole node types first: a QML "ui_object_definition" has no segment
    -- that says "container", and matching by segment alone left the map with
    -- one line per QML file.
    if TS_CONTAINER[node_type] then
        return true
    end
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
local function ts_wanted(node_type, ft)
    local data = data_nodes(ft)
    if data then
        return data[node_type] == true
    end
    if (FT_NODES[ft or ""] or {})[node_type] then
        return true
    end
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

-- ts_wanted on a node rather than a type, so the filetypes whose extra
-- nodes only count at the top of the file can be told where they are.
local function wanted_node(node, ft)
    if expression_bodied(node) then
        return false
    end
    local rule = (FT_NODES[ft or ""] or {})[node:type()]
    if rule == "top" then
        local parent = node:parent()
        return parent ~= nil and parent:parent() == nil
    end
    return ts_wanted(node:type(), ft)
end
-- The last line of a node that is actually part of it. A grammar whose
-- declarations run to the start of the next one - make rules and variables,
-- shell assignments, markdown sections - hands back the blank lines in
-- between as well, and they belong to the file's spacing rather than to the
-- declaration: an edit that replaced them would close the gap.
local function last_written_line(bufnr, first, last)
    while last > first do
        local text = vim.api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
        if text:match("%S") then break end
        last = last - 1
    end
    return last
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
    local ft = vim.bo[bufnr].filetype
    local out = {}
    local last_row = -1
    local extra, extra_last_row = 0, -1
    local function walk(node, depth)
        for child in node:iter_children() do
            if child:named() then
                if wanted_node(child, ft) then
                    local srow, _, erow, ecol = child:range()
                    if ecol == 0 and erow > srow then
                        erow = erow - 1
                    end
                    erow = last_written_line(bufnr, srow + 1, erow + 1) - 1
                    -- A wrapper and its inner node often start on the same
                    -- row (e.g. declaration + definition); emit it once.
                    if #out >= MAX_SKIM_ENTRIES then
                        -- Past the cap, count everything left out: counting
                        -- only depth<=1 told a QML file with 62 objects below
                        -- the cut that 2 were missing.
                        if srow ~= extra_last_row then
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
                elseif not data_opaque(child:type(), ft) then
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
    local files_capped = 0
    if #files > MAX_QUERY_FILES then
        files_capped = #files - MAX_QUERY_FILES
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
    -- One match can produce several captures, and each is an entry: a query
    -- with two @captures over 38 call sites reported "count: 76".
    local places = {}
    for _, m in ipairs(matches) do
        places[("%s:%d"):format(m.file, m.line)] = true
    end
    local res = { count = #matches, places = vim.tbl_count(places), matches = matches }
    if res.places ~= res.count then
        res.count_note = ("count is captures; the query matched %d place(s)"):format(res.places)
    end
    if #skipped > 0 then
        res.skipped = skipped
    end
    if #matches >= MAX_QUERY_MATCHES then
        res.note = ("truncated at %d matches"):format(MAX_QUERY_MATCHES)
    end
    if files_capped > 0 then
        -- Silence here answered a 555-file glob out of the first 50 files and
        -- reported the count as though it covered the tree.
        res.files_note = ("only the first %d files were searched; %d more matched the glob and "
            .. "were not looked at - narrow it"):format(MAX_QUERY_FILES, files_capped)
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
            -- A file with no declarations falls back to the server's
            -- symbols, and for a data table that is every value in it. The
            -- keys are the outline; the values are the file.
            local dropped_values = 0
            local function lsp_outline(timeout_ms)
                local okc, client = pcall(get_client, bufnr,
                    "textDocument/documentSymbol", timeout_ms)
                if not okc then return nil end
                local okr, syms = pcall(request, client, bufnr,
                    "textDocument/documentSymbol",
                    { textDocument = { uri = vim.uri_from_bufnr(bufnr) } })
                if not okr then return nil end
                local opts = { drop_values = true }
                local flat = flatten_symbols(syms, 0, {}, bufnr, opts)
                dropped_values = opts.dropped or 0
                -- Some servers answer alphabetically (pyright does), which
                -- reads as a shuffled file; and an outline is a map, so it
                -- takes the same cap the treesitter one has.
                table.sort(flat, function(a, b)
                    return (tonumber(a:match("^%s*(%d+)")) or 0) < (tonumber(b:match("^%s*(%d+)")) or 0)
                end)
                if #flat > MAX_SKIM_ENTRIES then
                    local extra = #flat - MAX_SKIM_ENTRIES
                    flat = vim.list_slice(flat, 1, MAX_SKIM_ENTRIES)
                    flat[#flat + 1] = ("… +%d more declarations; find_symbol or read_file with "
                        .. "offset reach them"):format(extra)
                end
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
                if dropped_values > 0 then
                    entry.note = ("%d list entries are left out: they are values, named after "
                        .. "their own text, and read_file shows them"):format(dropped_values)
                end
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
    local last_row = -1
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
                if wanted_node(child, ft) then
                    local srow = child:range()
                    if srow == last_row then
                        -- Several declarations on one line (a one-line JSON
                        -- object) are one line of the map.
                    elseif #out >= budget then
                        extra = extra + 1
                    else
                        last_row = srow
                        local text = (lines[srow + 1] or ""):gsub("^%s+", "")
                        if #text > MAP_TEXT_MAX then
                            text = text:sub(1, MAP_TEXT_MAX) .. "…"
                        end
                        out[#out + 1] = ("%s%d: %s"):format(("  "):rep(depth), srow + 1, text)
                    end
                    if depth < MAP_MAX_DEPTH and ts_container(ctype, ft) then
                        walk(child, depth + 1)
                    end
                elseif not ts_opaque(ctype) and not data_opaque(ctype, ft) then
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

-- Every project file under `target`, relative to it and path-sorted: git's
-- view when it is a repository (tracked plus untracked, ignores honoured),
-- the filesystem otherwise. git lists tracked files before untracked ones;
-- a sorted list is easier to scan and stable across runs.
local function list_project_files(target)
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
    table.sort(files)
    return files
end

-- Workspace tree: the directory structure with aggregated stats, and the
-- files that matter most, cut to a line budget. Line counts come from one
-- wc pass and binaries from git's own classification, so it costs a few
-- hundred milliseconds on a monorepo where workspace_map would parse for
-- minutes. open_workspace's reply carries the root's tree, as the check
-- that the right project was opened and the hint which subdirectory to map
-- next; the tool zooms into one.
local TREE_BUDGET = 40
local TREE_BUDGET_MAX = 400
local TREE_DEPTH = 2
local TREE_DEPTH_MAX = 8
-- Biggest files a directory line names, as a hint to what to read there.
local TREE_BIGGEST = 2
-- Directory names that usually hold code nobody here wrote.
local VENDOR_DIRS = {
    node_modules = true, vendor = true, third_party = true, ["third-party"] = true,
    [".deps"] = true, dist = true, build = true, target = true,
}
-- Binary by extension, for a tree with no git to ask.
local BINARY_EXT = {
    png = true, jpg = true, jpeg = true, gif = true, ico = true, webp = true, bmp = true,
    pdf = true, zip = true, gz = true, tgz = true, xz = true, bz2 = true, tar = true, ["7z"] = true,
    woff = true, woff2 = true, ttf = true, otf = true, eot = true,
    so = true, o = true, a = true, dylib = true, dll = true, exe = true, bin = true, wasm = true,
    mp3 = true, mp4 = true, ogg = true, wav = true, mov = true, webm = true,
    sqlite = true, db = true, pyc = true, class = true, jar = true,
}

local function fmt_count(n)
    if n < 1000 then return tostring(n) end
    if n < 10000 then return ("%.1fk"):format(n / 1000) end
    return ("%dk"):format(math.floor(n / 1000 + 0.5))
end

local function plural(n, word)
    return fmt_count(n) .. " " .. word .. (n == 1 and "" or "s")
end

-- Which of the project files are binary. git knows (it classified them
-- when it hashed them: "w/-text" in --eol output); elsewhere the extension
-- has to do.
local function binary_files(target, files)
    local set = {}
    local out = vim.fn.systemlist({ "git", "-C", target, "ls-files", "--eol",
        "--cached", "--others", "--exclude-standard" })
    if vim.v.shell_error == 0 then
        for _, line in ipairs(out) do
            local w, path = line:match("^i/%S*%s+w/(%S*)%s+attr/%S*%s+(.*)$")
            if w == "-text" and path then
                set[path] = true
            end
        end
        return set, true
    end
    for _, rel in ipairs(files) do
        local ext = rel:match("%.([%w]+)$")
        if ext and BINARY_EXT[ext:lower()] then
            set[rel] = true
        end
    end
    return set, false
end

-- Line counts for many files in one wc pass (chunked, so a monorepo does
-- not overflow the argument list). Files that are gone from disk but still
-- tracked come back nil.
local function count_lines(target, files)
    local counts = {}
    local CHUNK = 500
    for i = 1, #files, CHUNK do
        local cmd = { "wc", "-l" }
        for j = i, math.min(i + CHUNK - 1, #files) do
            cmd[#cmd + 1] = target .. "/" .. files[j]
        end
        for _, line in ipairs(vim.fn.systemlist(cmd)) do
            local n, path = line:match("^%s*(%d+)%s+(.*)$")
            if n and path ~= "total" and path:sub(1, #target + 1) == target .. "/" then
                counts[path:sub(#target + 2)] = tonumber(n)
            end
        end
        sleep(0)
    end
    return counts
end

local function workspace_tree(args)
    local root = args.root
    if type(root) ~= "string" or root == "" then
        err("missing project root")
    end
    local target = root
    if type(args.path) == "string" and args.path ~= "" then
        target = args.path:sub(1, 1) == "/" and args.path or (root .. "/" .. args.path)
        if vim.fn.isdirectory(target) == 0 then
            err("not a directory: %s", target)
        end
    end
    target = target:gsub("/+$", "")
    local max_depth = math.max(1, math.min(TREE_DEPTH_MAX, tonumber(args.depth) or TREE_DEPTH))
    local budget = math.max(5, math.min(TREE_BUDGET_MAX, tonumber(args.budget) or TREE_BUDGET))

    local files = list_project_files(target)
    local binaries, from_git = binary_files(target, files)
    local text_files = {}
    for _, rel in ipairs(files) do
        if not binaries[rel] then
            text_files[#text_files + 1] = rel
        end
    end
    local counts = count_lines(target, text_files)
    -- Declaration counts are a parse per file: worth it while the project is
    -- small enough that the map would have listed them anyway.
    local decls
    if #text_files <= MAP_SMALL_PROJECT then
        decls = {}
        for _, rel in ipairs(text_files) do
            local outline = top_level_outline(target .. "/" .. rel, 100000)
            if outline then
                decls[rel] = #outline
            end
        end
    end
    local ft_cache = {}
    local function file_type(rel)
        local key = rel:match("%.([%w_]+)$") or vim.fs.basename(rel)
        key = key:lower()
        local cached = ft_cache[key]
        if cached == nil then
            cached = vim.filetype.match({ filename = rel }) or false
            ft_cache[key] = cached
        end
        return cached or nil
    end

    -- Pass 1: every directory with what is under it, at any depth.
    local dirs = {}
    local function dir_at(key)
        local d = dirs[key]
        if not d then
            d = { path = key, files = 0, lines = 0, decls = 0, tests = 0, binaries = 0,
                fts = {}, biggest = {}, children = {}, direct = {} }
            dirs[key] = d
        end
        return d
    end
    dir_at("")
    local total_lines, missing = 0, 0
    for _, rel in ipairs(files) do
        local binary = binaries[rel] or false
        local lines = counts[rel]
        if not binary and lines == nil then
            missing = missing + 1
        else
            lines = lines or 0
            total_lines = total_lines + lines
            local ft = (not binary) and file_type(rel) or nil
            local test = is_test_path(rel)
            local parts = vim.split(rel, "/", { plain = true })
            local name = parts[#parts]
            local entry = { rel = rel, name = name, lines = lines, binary = binary,
                decls = decls and decls[rel] or nil }
            local key = ""
            for k = 0, #parts - 1 do
                if k > 0 then
                    local child = key == "" and parts[k] or (key .. "/" .. parts[k])
                    dir_at(key).children[child] = true
                    key = child
                end
                local d = dir_at(key)
                d.files = d.files + 1
                d.lines = d.lines + lines
                d.decls = d.decls + (entry.decls or 0)
                if test then d.tests = d.tests + 1 end
                if binary then
                    d.binaries = d.binaries + 1
                elseif ft then
                    d.fts[ft] = (d.fts[ft] or 0) + 1
                end
                if not binary then
                    local b = d.biggest
                    b[#b + 1] = entry
                    table.sort(b, function(x, y) return x.lines > y.lines end)
                    if #b > TREE_BIGGEST then b[#b] = nil end
                end
            end
            local parent = dir_at(key)
            parent.direct[#parent.direct + 1] = entry
        end
    end

    -- Pass 2: the shape to show. A chain of single-child directories with
    -- nothing else in them (lua/agent99/, src/main/java/...) is one line
    -- and one level, since the middle names carry no information.
    local function child_count(d)
        local n = 0
        for _ in pairs(d.children) do n = n + 1 end
        return n
    end
    local function walk(key, depth)
        local d = dirs[key]
        if key ~= "" then
            while #d.direct == 0 and child_count(d) == 1 do
                d = dirs[next(d.children)]
            end
        end
        local node = { dir = d, label = d.path, depth = depth, kids = {}, hidden_subdirs = 0 }
        local children = vim.tbl_keys(d.children)
        table.sort(children)
        if depth < max_depth then
            for _, child in ipairs(children) do
                node.kids[#node.kids + 1] = walk(child, depth + 1)
            end
        else
            node.hidden_subdirs = #children
        end
        return node
    end
    local tree = walk("", 0)

    -- Budget, in three rounds. Root files first, up to a third of it: a
    -- Makefile or a go.mod is twenty lines that say how the project is
    -- built, and they are what tells a wrong root from the right one.
    -- Then directories, the skeleton, largest first (size discounted per
    -- level). Then the remaining files by the same discounted size, so a
    -- file two levels down needs four times the lines of a top-level one
    -- to outrank it. A directory whose files all missed the cut says so on
    -- its own line already ("40 files"), so it gets no "+N more" line;
    -- one that shows some of its files does, and that line is budgeted.
    local function score(lines, depth)
        return lines * (0.5 ^ depth)
    end
    local dir_nodes, root_files, file_entries = {}, {}, {}
    local function collect(node)
        for _, kid in ipairs(node.kids) do
            kid.parent = node
            dir_nodes[#dir_nodes + 1] = kid
            collect(kid)
        end
        -- Binaries are counted on the directory line and never listed; a
        -- directory holding one file and nothing else is rendered as that
        -- file, so its contents are not a separate line.
        if node ~= tree and #node.dir.direct == 1 and next(node.dir.children) == nil then
            node.single = node.dir.direct[1]
            return
        end
        for _, f in ipairs(node.dir.direct) do
            if not f.binary then
                local fe = { node = node, entry = f, score = score(f.lines, node.depth) }
                if node == tree then
                    root_files[#root_files + 1] = fe
                else
                    file_entries[#file_entries + 1] = fe
                end
            end
        end
    end
    collect(tree)
    local function by_score(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.entry.rel < b.entry.rel
    end
    table.sort(root_files, by_score)
    table.sort(file_entries, by_score)
    table.sort(dir_nodes, function(a, b)
        local sa, sb = score(a.dir.lines, a.depth), score(b.dir.lines, b.depth)
        if sa ~= sb then return sa > sb end
        return a.label < b.label
    end)

    local shown_files, shown_dirs, used = {}, {}, 0
    -- Round 1: root files.
    local root_cap = math.floor(budget / 3)
    for i, fe in ipairs(root_files) do
        if i > root_cap then break end
        shown_files[fe.entry] = true
        used = used + 1
    end
    -- Round 2: directories. A parent always ranks at or above its children
    -- (more lines, shallower), so they come in an order where a shown
    -- directory's ancestors are shown too.
    local dirs_cut = 0
    for _, node in ipairs(dir_nodes) do
        if used < budget then
            shown_dirs[node] = true
            used = used + 1
        else
            dirs_cut = dirs_cut + 1
        end
    end
    local function ancestors_shown(node)
        local n = node
        while n and n ~= tree do
            if not shown_dirs[n] then return false end
            n = n.parent
        end
        return true
    end
    -- Round 3: the rest of the files, in one ranked list, with the root's
    -- leftovers competing on equal terms.
    for i = root_cap + 1, #root_files do
        file_entries[#file_entries + 1] = root_files[i]
    end
    table.sort(file_entries, by_score)
    local candidates = {}
    for _, fe in ipairs(file_entries) do
        if ancestors_shown(fe.node) then
            candidates[#candidates + 1] = fe
        end
    end
    -- Lines a "+N more files" summary costs: one per directory that shows
    -- some of its files but not all.
    local function summary_lines()
        local partial, n = {}, 0
        for _, fe in ipairs(candidates) do
            if not shown_files[fe.entry] and not partial[fe.node] then
                -- Does this directory show any file?
                for _, other in ipairs(fe.node.dir.direct) do
                    if shown_files[other] then
                        partial[fe.node] = true
                        n = n + 1
                        break
                    end
                end
            end
        end
        return n
    end
    local taken = 0
    for _, fe in ipairs(candidates) do
        if used + taken >= budget then break end
        shown_files[fe.entry] = true
        taken = taken + 1
    end
    -- Summary lines take slots too; give back the lowest-ranked files until
    -- everything fits (a directory losing its last shown file loses its
    -- summary line with it).
    local over = used + taken + summary_lines() - budget
    for i = #candidates, 1, -1 do
        if over <= 0 then break end
        local fe = candidates[i]
        if shown_files[fe.entry] then
            shown_files[fe.entry] = nil
            taken = taken - 1
            over = used + taken + summary_lines() - budget
        end
    end
    local omitted = {}
    for _, fe in ipairs(candidates) do
        if not shown_files[fe.entry] then
            omitted[fe.node] = (omitted[fe.node] or 0) + 1
        end
    end
    for node, _ in pairs(omitted) do
        local any = false
        for _, f in ipairs(node.dir.direct) do
            if shown_files[f] then any = true break end
        end
        if not any then omitted[node] = nil end
    end
    local n_omit_lines = 0
    for _ in pairs(omitted) do n_omit_lines = n_omit_lines + 1 end

    -- Render in tree order.
    local out = {}
    local function file_line(entry, indent)
        local desc
        if entry.binary then
            desc = "binary"
        else
            desc = plural(entry.lines, "line")
            if entry.decls then
                desc = desc .. ", " .. entry.decls .. " decls"
            end
        end
        return ("%s%s  %s"):format(("  "):rep(indent), entry.name, desc)
    end
    local function dir_line(node)
        local d = node.dir
        if node.single then
            local f = node.single
            local desc = f.binary and "binary" or plural(f.lines, "line")
            if f.decls then desc = desc .. ", " .. f.decls .. " decls" end
            return ("%s%s/%s  %s"):format(("  "):rep(node.depth - 1), node.label, f.name, desc)
        end
        local parts = { plural(d.files, "file") }
        if d.lines > 0 then
            parts[#parts + 1] = plural(d.lines, "line")
        end
        if decls and d.decls > 0 then
            parts[#parts + 1] = d.decls .. " decls"
        end
        local fts = vim.tbl_keys(d.fts)
        table.sort(fts, function(a, b)
            if d.fts[a] ~= d.fts[b] then return d.fts[a] > d.fts[b] end
            return a < b
        end)
        local langs = {}
        for i = 1, math.min(2, #fts) do langs[#langs + 1] = fts[i] end
        if #fts > 2 then langs[#langs + 1] = "+" .. (#fts - 2) end
        if d.binaries > 0 and d.binaries == d.files then
            langs = { "binary" }
        elseif d.binaries > 0 then
            langs[#langs + 1] = d.binaries .. " binary"
        end
        if #langs > 0 then
            parts[#parts + 1] = table.concat(langs, " ")
        end
        local line = ("%s%s/  %s"):format(("  "):rep(node.depth - 1), node.label, table.concat(parts, "  "))
        local extras = {}
        if #d.biggest > 0 and d.files > 1 then
            local names = {}
            for _, b in ipairs(d.biggest) do
                names[#names + 1] = b.name .. " " .. fmt_count(b.lines)
            end
            extras[#extras + 1] = table.concat(names, ", ")
        end
        if d.tests > 0 then
            extras[#extras + 1] = d.tests .. " tests"
        end
        if node.hidden_subdirs > 0 then
            extras[#extras + 1] = ("+%d subdirectories"):format(node.hidden_subdirs)
        end
        if #extras > 0 then
            line = line .. " (" .. table.concat(extras, "; ") .. ")"
        end
        if VENDOR_DIRS[vim.fs.basename(node.label)] then
            line = line .. " [vendored?]"
        end
        return line
    end
    local function render(node)
        local direct = vim.list_slice(node.dir.direct)
        table.sort(direct, function(a, b)
            if a.lines ~= b.lines then return a.lines > b.lines end
            return a.name < b.name
        end)
        for _, f in ipairs(direct) do
            if shown_files[f] then
                out[#out + 1] = file_line(f, node.depth)
            end
        end
        if omitted[node] then
            out[#out + 1] = ("%s… +%d more files"):format(("  "):rep(node.depth), omitted[node])
        end
        for _, kid in ipairs(node.kids) do
            if shown_dirs[kid] then
                out[#out + 1] = dir_line(kid)
                render(kid)
            end
        end
    end
    render(tree)

    local notes = {}
    if dirs_cut > 0 then
        notes[#notes + 1] = ("%d directories did not fit the budget of %d lines; raise budget=, "
            .. "or zoom with path="):format(dirs_cut, budget)
    end
    if n_omit_lines > 0 or tree.hidden_subdirs > 0 or #dir_nodes > 0 then
        notes[#notes + 1] = "workspace_tree(path=<dir>) zooms in; workspace_map(path=<dir>) lists "
            .. "the declarations of the files there"
    end
    if not from_git then
        notes[#notes + 1] = "not a git repository: nothing is ignored, and binaries are guessed by extension"
    end
    if missing > 0 then
        notes[#notes + 1] = ("%d tracked files are missing from disk"):format(missing)
    end
    return {
        root = target,
        depth = max_depth,
        file_count = #files,
        line_count = total_lines,
        tree = out,
        note = #notes > 0 and table.concat(notes, ". ") or nil,
    }
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
    local files = list_project_files(target)
    local tests_skipped = 0
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
    -- Tests are left out to keep a big map readable; in a small project
    -- they are the spec (a bug-fix task starts from the failing test) and
    -- the map has room for them, so they stay in unless asked otherwise.
    --
    -- After the glob, not before it: a glob narrowing to twenty files was
    -- answered with "3228 test files left out", the whole repository's count,
    -- and the same repository-wide size decided whether tests were dropped
    -- from a handful of files at all.
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
    -- Vendored trees last. The cap is on files, and the list is path-sorted,
    -- so a monorepo with a `.repos/` checkout of two other projects spent all
    -- 200 of its slots there, alphabetically, before reaching apps/: ten
    -- thousand tokens of somebody else's code and none of this one's.
    local vendored = {}
    local own = {}
    for _, f in ipairs(files) do
        if f:match("^%.?repos/") or f:match("^vendor/") or f:match("/vendor/")
            or f:match("^third_party/") or f:match("/third_party/")
            or f:match("^external/") or f:match("/external/")
            or f:match("site%-packages/") then
            vendored[#vendored + 1] = f
        else
            own[#own + 1] = f
        end
    end
    if #vendored > 0 and #own > 0 then
        files = own
        vim.list_extend(files, vendored)
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
        if #vendored > 0 and #own > 0 then
            notes[#notes + 1] = ("%d of them are vendored (%s and the like) and were put last, "
                .. "so the cap falls on those first"):format(#vendored, vendored[1])
        end
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
    local inside, outside, seen_client, warming, failed
    local function collect()
        inside, outside, seen_client, warming, failed = {}, {}, false, false, {}
        for _, client in ipairs(vim.lsp.get_clients()) do
            if client:supports_method("workspace/symbol") then
                local bufnr = next(client.attached_buffers or {})
                if bufnr then
                    seen_client = true
                    if fresh_buf(bufnr) then warming = true end
                    -- One server timing out or erroring must not take the
                    -- others' answers with it; its failure is reported
                    -- beside what the rest found.
                    local okr, result = pcall(request, client, bufnr, "workspace/symbol", { query = query })
                    if not okr then
                        failed[#failed + 1] = ("%s: %s"):format(client.name,
                            tostring(result):gsub("\n", " "))
                        result = nil
                    end
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
    if #failed > 0 then
        note = ("%d server(s) did not answer: %s"):format(#failed, table.concat(failed, "; "))
            .. (note and ("; " .. note) or "")
    end
    return { count = #out, project_matches = project_matches, symbols = out, note = note }
end

local index_cache = {}

-- How long an index built without the language server (it did not attach
-- within ATTACH_TIMEOUT_MS) is served from the cache before the server is
-- asked for again.
local NO_SERVER_RETRY_MS = 60000

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
    local ntype = node:type()
    if ntype == "section" then
        local heading = section_name(node, bufnr)
        if heading then return heading end
    end
    -- Data files: a YAML or JSON pair is named by its key, a TOML table or
    -- pair by its first child (the key), a Dockerfile stage by its alias.
    local key = node:field("key")
    if key and key[1] then
        local text = vim.treesitter.get_node_text(key[1], bufnr)
        return (text:gsub('^"(.*)"$', "%1"):gsub("^'(.*)'$", "%1"))
    end
    if ntype == "table" or ntype == "table_array_element" or (ntype == "pair" and not node:field("name")[1]) then
        for child in node:iter_children() do
            if child:named() then
                return (vim.treesitter.get_node_text(child, bufnr):gsub('^"(.*)"$', "%1"))
            end
        end
    end
    if ntype == "from_instruction" then
        local image
        for child in node:iter_children() do
            if child:type() == "image_alias" then
                return vim.treesitter.get_node_text(child, bufnr)
            elseif child:type() == "image_spec" then
                image = vim.treesitter.get_node_text(child, bufnr)
            end
        end
        if image then return image end
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
    local ft = vim.bo[bufnr].filetype
    local entries = {}
    local function walk(node, prefix)
        for child in node:iter_children() do
            if child:named() then
                if wanted_node(child, ft) then
                    local srow, _, erow, ecol = child:range()
                    -- A node ending at column 0 stopped at the previous
                    -- line's newline (a Markdown section runs up to the
                    -- next heading): its last line is the one before.
                    if ecol == 0 and erow > srow then
                        erow = erow - 1
                    end
                    erow = last_written_line(bufnr, srow + 1, erow + 1) - 1
                    local name = ts_node_name(child, bufnr)
                    local path = prefix == "" and name or (prefix .. "/" .. name)
                    entries[#entries + 1] = {
                        path = path,
                        name = name,
                        kind = child:type(),
                        first = srow + 1,
                        last = erow + 1,
                    }
                    walk(child, path)
                elseif not data_opaque(child:type(), ft) then
                    walk(child, prefix)
                end
            end
        end
    end
    walk(trees[1]:root(), "")
    -- A Dockerfile stage is FROM up to the next FROM, but the grammar only
    -- has the one line; widen each stage to what it actually owns so a
    -- stage can be read and edited as a unit.
    if ft == "dockerfile" then
        local total = vim.api.nvim_buf_line_count(bufnr)
        for i, e in ipairs(entries) do
            if e.kind == "from_instruction" then
                local stop = total
                for j = i + 1, #entries do
                    if entries[j].kind == "from_instruction" then
                        stop = entries[j].first - 1
                        break
                    end
                end
                while stop > e.first do
                    local text = vim.api.nvim_buf_get_lines(bufnr, stop - 1, stop, false)[1] or ""
                    if text:match("%S") then break end
                    stop = stop - 1
                end
                e.last = stop
            end
        end
    end
    return entries
end
-- Defined below, next to the merge that also uses it.
local statement_end

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
                local first, last = range.start.line + 1, range["end"].line + 1
                -- Widened here rather than where the server's symbols are
                -- merged into treesitter's, because a file that declares no
                -- function - a module of constants, the case this is for -
                -- has no treesitter entries at all and takes the server's
                -- list unmerged.
                if first == last then
                    last = statement_end(bufnr, first)
                end
                entries[#entries + 1] = {
                    path = path, name = s.name, kind = kind,
                    first = first, last = last,
                }
                walk(s.children, path)
            end
        end
    end
    walk(syms, "")
    return entries
end

-- Where the statement that starts on `first` actually ends. Some servers
-- report a variable by the range of its name alone - pyright does - so a
-- constant whose value spans eight lines arrives as a one-line symbol.
-- find_symbol then shows one line of it and replace_symbol_body writes over
-- that line, orphaning the rest of the value into a syntax error. Treesitter
-- has the whole statement: from the node at the name, climb while the parent
-- still starts on that line, and take the widest end.
function statement_end(bufnr, first)
    local line = vim.api.nvim_buf_get_lines(bufnr, first - 1, first, false)[1]
    if not line then return first end
    local col = (line:find("%S") or 1) - 1
    -- The parser is asked for and parsed here rather than through
    -- vim.treesitter.get_node, which answers nothing for a buffer nobody has
    -- parsed yet - every buffer these tools load from disk.
    local okp, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not okp or not parser then return first end
    local okt, trees = pcall(function() return parser:parse() end)
    if not okt or not trees or not trees[1] then return first end
    local node = trees[1]:root():named_descendant_for_range(first - 1, col, first - 1, col)
    local last = first
    -- Never the file's root node: a statement on the first line shares its
    -- start row, and taking it would widen every such symbol to the whole
    -- file.
    while node and node:parent() ~= nil do
        local srow, _, erow, ecol = node:range()
        if srow ~= first - 1 then break end
        -- A node ending at column 0 ends on the line before, not on the one
        -- its range points into.
        if ecol == 0 and erow > srow then erow = erow - 1 end
        if erow + 1 > last then last = erow + 1 end
        node = node:parent()
    end
    return last
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
    -- Covered by path, not by bare name: A/Name and B/Name are two fields
    -- of two structs, and one of them must not hide the other. An entry
    -- with no path falls back to its name. The same name on the same line
    -- is the same declaration, however the two sides nested it (a Go
    -- method under its receiver for the server, top-level for the
    -- grammar), and is not added twice.
    local function key(e)
        return e.path or e.name
    end
    local function same_decl(e)
        return (e.name or "") .. "\0" .. tostring(e.first)
    end
    local covered, declared = {}, {}
    for _, e in ipairs(entries) do
        covered[key(e)] = true
        declared[same_decl(e)] = true
    end
    for _, e in ipairs(from_lsp) do
        if not covered[key(e)] and not declared[same_decl(e)] then

            entries[#entries + 1] = e
            covered[key(e)] = true
            declared[same_decl(e)] = true
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
    if cached and cached.tick == tick then
        if cached.complete then
            return cached.entries
        end
        -- An index assembled without the server is served again for a
        -- while rather than rebuilt: the rebuild would wait the attach
        -- timeout once more, on every call, for a server that is not
        -- coming. It is retried when a client has attached since, or
        -- once the grace period is over.
        if cached.retry_after and vim.uv.now() < cached.retry_after
            and #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" }) == 0 then
            return cached.entries
        end
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
    index_cache[bufnr] = {
        tick = tick, entries = entries, complete = complete,
        retry_after = not complete and (vim.uv.now() + NO_SERVER_RETRY_MS) or nil,
    }
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

-- The files whose text mentions `text` at all, as ripgrep sees them, and
-- whether ripgrep was there to ask. Reading a file's symbol index means
-- loading its buffer and parsing it, which is far too much work to do for
-- every file in a project when a symbol can only be declared in a file that
-- spells its name somewhere.
local function files_mentioning(root, text, cap)
    if vim.fn.executable("rg") == 0 or type(root) ~= "string" or root == ""
        or type(text) ~= "string" or text == "" then
        return {}, false
    end
    local files = vim.fn.systemlist({
        "rg", "--files-with-matches", "--fixed-strings", "--max-count", "1",
        "--sort", "path", "--", text, root,
    })
    -- 1 is "no matches", which is an answer; anything above it is a failure.
    if vim.v.shell_error > 1 then
        return {}, false
    end
    if cap and #files > cap then
        files = vim.list_slice(files, 1, cap)
    end
    return files, true
end

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
    local found = {}
    for _, path in ipairs(files_mentioning(root, query, FALLBACK_MAX_FILES)) do
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
    -- One file named through file, files and glob at once is searched
    -- once, or every symbol in it would be reported as many times.
    local seen, unique = {}, {}
    for _, f in ipairs(files) do
        local abs = vim.fn.fnamemodify(f, ":p")
        if not seen[abs] then
            seen[abs] = true
            unique[#unique + 1] = f
        end
    end
    files = unique
    -- Nothing said where to look. Refusing was measured as one of the
    -- commonest failures in real sessions, and the recovery was always the
    -- same call again with a glob around the whole project, so do that here
    -- instead: ripgrep narrows the workspace to the files that spell the
    -- name at all, which is every file that could declare it.
    local scanned_project = false
    if #files == 0 and not glob_note then
        local hits, asked = files_mentioning(args.root, name:match("([^/]+)$") or name,
            MAX_QUERY_FILES)
        if asked then
            files, scanned_project = hits, true
        end
    end
    if #files == 0 then
        if glob_note then
            err("%s", glob_note)
        elseif scanned_project then
            err("no file under %s mentions %q; check the spelling, or pass file, "
                .. "files or glob to search somewhere else",
                rel_path(args.root or "."), name)
        end
        err("no files to search: pass file, files, or glob (searching the whole "
            .. "workspace needs ripgrep, which is not installed here)")
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
    -- The whole-workspace search is capped, and a cap that is silently hit
    -- reads as "the symbol is not there" when it means "we stopped looking".
    if scanned_project and #files >= MAX_QUERY_FILES then
        note = ("searched the first %d files mentioning the name; pass file or glob "
            .. "if it is declared elsewhere"):format(MAX_QUERY_FILES)
            .. (note and ("; " .. note) or "")
    end
    return {
        count = #found,
        matches = out,
        note = note,
    }
end

local MAX_NEAR_NAMES = 6

-- The names worth showing someone who asked for one this file does not
-- have: the ones that look like what was asked first, and failing that the
-- first few the file declares, which is enough to see whether the name path
-- was wrong or the file was.
local function near_names(index, name_path)
    local leaf = name_path:match("([^/]+)$") or name_path
    local lower = leaf:lower()
    local near, rest = {}, {}
    for _, entry in ipairs(index) do
        local name = entry.name or ""
        local close = match_rank(entry, leaf) ~= nil
            or (#name > 0 and lower:find(name:lower(), 1, true) ~= nil)
            or (#name >= 4 and #leaf >= 4 and name:sub(1, 4):lower() == lower:sub(1, 4))
        local into = close and near or rest
        if #into < MAX_NEAR_NAMES then
            into[#into + 1] = entry.path
        end
    end
    if #near > 0 then
        return "the closest names in it are " .. table.concat(near, ", ")
    end
    local more = #index > #rest and (" and %d more"):format(#index - #rest) or ""
    return ("it declares %s%s"):format(table.concat(rest, ", "), more)
end

-- Resolve one unambiguous symbol for an edit.
local function resolve_symbol(file, name_path, pick)
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
        -- A name that resolves to nothing is either a typo or a file whose
        -- declarations the editor cannot see at all, and the two need
        -- different answers. Naming what the file does declare settles it
        -- in one reply rather than in a find_symbol round trip.
        local index = symbol_index(bufnr)
        if #index == 0 then
            err("no symbols are indexed in %s, so no name_path can resolve there: "
                .. "nothing in the file parses as a declaration (no treesitter parser "
                .. "or language server for its filetype). Address the lines instead - "
                .. "absolute=true line numbers, or match with the text to replace",
                file)
        end
        err("no symbol named %q in %s; %s (skim lists the file's declarations, "
            .. "find_symbol searches for the name elsewhere)",
            name_path, file, near_names(index, name_path))
    end
    if #candidates > 1 and candidates[1].rank == candidates[2].rank then
        -- A tie: two declarations answer to the same fragment (a method
        -- name shared by two classes, an overload). The caller may know
        -- more than the name - the text it wants to replace, or the lines
        -- it wants - and can settle the tie from that; the refusal is for
        -- when nothing does.
        local tied = {}
        for _, c in ipairs(candidates) do
            if c.rank ~= candidates[1].rank then break end
            tied[#tied + 1] = c.entry
        end
        local chosen = pick and pick(bufnr, tied)
        if chosen then
            return bufnr, chosen
        end
        local names = {}
        for i, e in ipairs(tied) do
            if i > 5 then break end
            names[#names + 1] = e.path
        end
        err("ambiguous symbol %q in %s: %s - use the full name path",
            name_path, file, table.concat(names, ", "))
    end
    return bufnr, candidates[1].entry
end

-- Filetypes where a line starting with # is not a comment: a preprocessor
-- directive in the C family, a private field in JS/TS, a selector in CSS,
-- a heading in Markdown. Consulted only when 'commentstring' does not say.
local HASH_NOT_COMMENT = {
    c = true, cpp = true, objc = true, objcpp = true, cuda = true,
    glsl = true, hlsl = true,
    javascript = true, javascriptreact = true, typescript = true, typescriptreact = true,
    css = true, scss = true, less = true, html = true, markdown = true,
}

-- Whether # opens a line comment in this buffer's language. The filetype's
-- commentstring answers when it is set (python, sh, yaml, toml, make, ruby
-- and perl all say "# %s"); otherwise the table above rules the C family
-- and friends out, and anything unknown keeps the old permissive answer.
local function hash_is_comment(bufnr)
    local cs = vim.bo[bufnr].commentstring or ""
    if cs ~= "" then
        return cs:match("^%s*#") ~= nil
    end
    return not HASH_NOT_COMMENT[vim.bo[bufnr].filetype]
end

-- Whether a stripped line reads as (part of) a comment block, by its
-- leader. Language-agnostic apart from the # question above, since an
-- #endif over a C function is not its doc comment and must not travel
-- with it or have a sibling inserted above it.
local function comment_leader(s, hash_ok)
    return s:match("^%-%-") ~= nil or s:match("^//") ~= nil
        or (hash_ok and s:match("^#") ~= nil)
        or s:match("^/%*") ~= nil or s:match("^%*") ~= nil
        or s:match([[^"""]]) ~= nil
end

-- The first line of the comment block sitting directly above `lnum`, or
-- lnum itself when there is none: a symbol's doc comment.
local function doc_block_start(bufnr, lnum)
    local first = lnum
    local hash_ok = hash_is_comment(bufnr)
    for l = lnum - 1, 1, -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local stripped = text:gsub("^%s+", "")
        if comment_leader(stripped, hash_ok) then
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
    local hash_ok = hash_is_comment(bufnr)
    for l = lnum - 1, 1, -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local s = text:gsub("^%s+", "")
        if s:match("^@")       -- TS/JS/Java/Python decorator
            or s:match("^#%[") -- Rust attribute
            or comment_leader(s, hash_ok) then
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
    local hash_ok = hash_is_comment(bufnr)
    for l = lnum - 1, math.max(1, lnum - 8), -1 do
        local text = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1] or ""
        local stripped = text:gsub("^%s+", "")
        if comment_leader(stripped, hash_ok) then
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
    -- A hit on a declaration's first line is that declaration only where the
    -- name is. `DB = os.environ.get("NOTES_DB", "notes.db")` declares DB and
    -- quotes NOTES_DB in a string on the same line, and calling the whole
    -- line "def" kept that string match under kind=code - the one thing the
    -- filter exists to drop.
    local on_decl = entry ~= nil and entry.first == line
    if on_decl then
        local c = tonumber(col)
        local text = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1]
        local name = (entry.name or ""):match("[^%.:/]+$")
        if not c or not text or not name or name == "" then
            return "def"
        end
        local s, e = text:find("%f[%w_]" .. name:gsub("%W", "%%%0") .. "%f[^%w_]")
        if s and c >= s and c <= e then
            return "def"
        end
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
    -- A double-quoted shell string is live code: `cd "$PROJECT_DIR"` expands
    -- inside it, and calling it a string literal made kind=code skip exactly
    -- the occurrences a rename has to change - three scripts were left
    -- assigning the new name and reading the old one, reported as a clean
    -- success. Only a single-quoted string (raw_string) is inert.
    local ft = vim.bo[bufnr].filetype
    local shell = ft == "sh" or ft == "bash" or ft == "zsh" or ft == "ksh"
    local n = node
    while n do
        local t = n:type()
        if t:find("comment", 1, true) then
            return "comment"
        end
        if t:find("string", 1, true) and not (shell and t == "string") then
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
    -- On the declaration's line but not on its name, and nothing else claimed
    -- it: still that declaration's line.
    return on_decl and "def" or nil
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
M.workspace_tree = workspace_tree
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
-- Exported for tests/unit_index.lua: the widening that keeps a constant
-- whose value spans lines from arriving as a one-line symbol.
M.statement_end = statement_end

return M
