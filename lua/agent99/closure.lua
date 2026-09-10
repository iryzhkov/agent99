-- The files an edit can break through the file it edited: worked out,
-- loaded and asked before the verdict is taken.
--
-- A language server publishes diagnostics for the documents it has been told
-- about, and it is told about a document when something opens it. An edit
-- that changes a symbol's shape breaks the files that use that symbol, and
-- when nothing has opened those files nothing ever asks about them. A Go
-- return type changed from int to string broke four packages and the reply
-- read "no new errors or warnings"; the warmer the server, the cleaner that
-- false verdict looked, because a warm server had already answered for the
-- edited file and had nothing more to say about it. Java behaves the same
-- way. Python and TypeScript pass the same fixture, because pyright and
-- tsserver re-check the importers of an open file on their own - which is
-- exactly why this cannot be left to the server.
--
-- What is computed here is a closure over textDocument/references, two hops
-- deep: the files that use what the edited file declares, and the files that
-- use what those files declare. The second hop is what reaches a file whose
-- error never names the edited symbol at all - `usera.Val` changed type
-- because `core.Compute` did, and `userd` fails on `usera.Val`.
--
-- Where the closure cannot be computed - no server, no references support,
-- nothing indexed to ask about - that is said in the reply. A verdict whose
-- scope is unknown is stated, not guessed.

local M = {}

local core = require("agent99.core")
local index = require("agent99.index")

-- Bounds. A closure is paid for on every edit that has one, so it buys the
-- common case (a handful of dependents) and stops rather than turning one
-- edit into a project-wide analysis. Every cap that bites is reported.
local MAX_FILES = 24        -- files loaded into one closure
local MAX_REQUESTS = 40     -- references requests spent on one closure
local EXPAND_FROM = 10      -- first-hop files worth asking a second hop from
local MAX_SEEDS = 10        -- declarations asked about per file
local DECL_LINES = 8        -- lines of a declaration searched for its name

-- The name as a call site writes it: the symbol index spells a Go method
-- `(*Archiver).Do` and a Lua field `M.greet`, and neither spelling is what
-- sits under the cursor at the declaration.
local function bare(name)
    return (name or ""):match("[^%.:/]+$") or name
end

-- Where the name sits in the declaration, which is what a references request
-- needs. The index reports the block a symbol occupies, not the column its
-- name is at, so the first lines of the block are searched for it.
local function position_of(bufnr, entry)
    local name = bare(entry.name or entry.path)
    if not name or name == "" then return nil end
    local first = entry.first or 1
    local last = math.min(entry.last or first, first + DECL_LINES)
    for i = first, last do
        local text = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
        local s = text:find(name, 1, true)
        if s then return i - 1, s - 1 end
    end
    return nil
end

-- The top-level declarations of a buffer, as the things other files can be
-- using. Anything nested is scoped to the symbol around it and cannot be
-- referenced from another file.
local function top_level(bufnr, limit)
    local out = {}
    local ok, entries = pcall(index.symbol_index, bufnr)
    if not ok or type(entries) ~= "table" then return out end
    for _, e in ipairs(entries) do
        if e.name and e.name ~= "" and not (e.path or ""):find("/", 1, true) then
            out[#out + 1] = e
            if #out >= limit then break end
        end
    end
    return out
end

local function ask_references(client, bufnr, entry, add)
    local line, col = position_of(bufnr, entry)
    if not line then return false end
    local ok, refs = pcall(core.request, client, bufnr, "textDocument/references", {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = line, character = col },
        context = { includeDeclaration = false },
    })
    if ok and type(refs) == "table" then
        for _, r in ipairs(refs) do
            if r.uri then add(vim.uri_to_fname(r.uri)) end
        end
    end
    return true
end

-- Compute the closure and load it. Returns a descriptor the edit report
-- reads; it is never nil, and `computable` says whether the reference graph
-- could be followed at all.
--
-- spec:
--   bufnr       the edited buffer (nil once the file is gone)
--   seeds       declarations to ask about; default: the top-level ones this
--               buffer declares, narrowed to `region` when that hits any
--   region      { first, last }, 1-based, the lines the edit covers
--   exclude     { [absolute path] = true }, files this call edits itself
--   extra_paths files that belong in the closure whatever references say
--   settle      called with each loaded buffer, before the snapshot
function M.plan(spec)
    spec = spec or {}
    local cl = {
        also = {}, names = {}, checked = {}, direct = 0, indirect = 0,
        computable = false, capped = false, reason = nil,
    }
    local settle = spec.settle or function(_) end
    local root = spec.root or vim.fn.getcwd()
    local bufnr = spec.bufnr
    if bufnr and not vim.api.nvim_buf_is_valid(bufnr) then bufnr = nil end

    local exclude = {}
    for path in pairs(spec.exclude or {}) do
        exclude[vim.fn.fnamemodify(path, ":p")] = true
    end
    if bufnr then exclude[vim.api.nvim_buf_get_name(bufnr)] = true end

    local why, order = {}, {}
    local function add(file, reached)
        if type(file) ~= "string" or file == "" then return end
        file = vim.fn.fnamemodify(file, ":p")
        if exclude[file] or why[file] then return end
        -- A reference into the standard library or a module cache is not a
        -- file this edit can break, and loading it would charge the reply
        -- with whatever the server thinks of somebody else's code.
        if root ~= "" and file:sub(1, #root + 1) ~= root .. "/" then return end
        if vim.fn.filereadable(file) == 0 then return end
        if #order >= MAX_FILES then
            cl.capped = true
            return
        end
        why[file] = reached
        order[#order + 1] = file
    end

    -- Files named outright: an undo that could not reverse an entry leaves
    -- that file half-written, and it has to be asked whatever the reference
    -- graph says about it.
    for _, path in ipairs(spec.extra_paths or {}) do add(path, "named") end

    local seeds = spec.seeds
    if not seeds and bufnr then
        seeds = top_level(bufnr, MAX_SEEDS)
        if spec.region then
            local within = {}
            for _, e in ipairs(seeds) do
                if not ((e.last or e.first or 0) < spec.region.first
                        or (e.first or 0) > spec.region.last) then
                    within[#within + 1] = e
                end
            end
            -- An edit that lands between declarations (an import block, a
            -- top-level statement) narrows to nothing; ask about the file's
            -- declarations rather than about none of them.
            if #within > 0 then seeds = within end
        end
    end
    seeds = seeds or {}
    local seen_name = {}
    for _, e in ipairs(seeds) do
        local n = bare(e.name or e.path)
        if n and n ~= "" and not seen_name[n] then
            seen_name[n] = true
            cl.names[#cl.names + 1] = n
        end
    end

    -- Buffers are loaded as the hops find them, and settled before the
    -- caller's diagnostics snapshot, so the problems these files already had
    -- are in the baseline and only what this edit breaks in them is new.
    local loaded, cursor = {}, 0
    local function load_found()
        while cursor < #order do
            cursor = cursor + 1
            local file = order[cursor]
            local okb, b = pcall(core.load_buf, file)
            if okb then
                loaded[file] = b
                cl.also[b] = true
                settle(b)
            else
                why[file] = nil
            end
        end
    end

    local client = bufnr and core.client_for(bufnr, "textDocument/references") or nil
    if not client or #seeds == 0 then
        if not bufnr then
            cl.reason = "the edited file is gone, so nothing could be asked which files used it"
        elseif #vim.lsp.get_clients({ bufnr = bufnr }) == 0 then
            cl.reason = "no language server is attached to this file"
        elseif not client then
            cl.reason = "the language server here answers no reference requests"
        else
            cl.reason = "nothing in this file is indexed as a declaration, so there was "
                .. "nothing to ask which files use it"
        end
        load_found()
        M.finish(cl, order, why)
        return cl
    end

    cl.computable = true
    local requests = 0
    for _, e in ipairs(seeds) do
        if requests >= MAX_REQUESTS then
            cl.capped = true
            break
        end
        if ask_references(client, bufnr, e, function(f) add(f, "direct") end) then
            requests = requests + 1
        end
    end
    local first_hop = vim.list_slice(order, 1, #order)
    load_found()

    -- The second hop, which is the one that matters: a file that breaks
    -- because a file it imports changed shape carries an error naming
    -- neither the edited symbol nor the edited file, and no first-hop
    -- closure reaches it. Only from a first hop small enough that the
    -- second is bounded - past that the edit is broad enough that
    -- check_project is the honest answer, and the reply says so.
    if #first_hop > 0 and #first_hop <= EXPAND_FROM and not cl.capped then
        for _, file in ipairs(first_hop) do
            local b = loaded[file]
            local c2 = b and core.client_for(b, "textDocument/references") or nil
            if c2 then
                for _, e in ipairs(top_level(b, MAX_SEEDS)) do
                    if requests >= MAX_REQUESTS then
                        cl.capped = true
                        break
                    end
                    if ask_references(c2, b, e, function(f) add(f, "indirect") end) then
                        requests = requests + 1
                    end
                end
            end
        end
        load_found()
    elseif #first_hop > EXPAND_FROM then
        cl.capped = true
    end

    M.finish(cl, order, why)
    return cl
end

-- Turn the collected paths into the list the reply carries.
function M.finish(cl, order, why)
    local checked = {}
    for _, file in ipairs(order) do
        if why[file] then
            checked[#checked + 1] = core.rel_path(file)
            if why[file] == "indirect" then
                cl.indirect = cl.indirect + 1
            else
                cl.direct = cl.direct + 1
            end
        end
    end
    table.sort(checked)
    cl.checked = checked
    return cl
end

local function plural(n, one, many)
    return n == 1 and one or many
end

-- Two closures as one, for a call that has more than one starting point:
-- an undo step that touched three files asks each of them who uses it.
function M.merge(a, b)
    if not a then return b end
    if not b then return a end
    local out = {
        also = {}, names = {}, checked = {},
        direct = a.direct + b.direct, indirect = a.indirect + b.indirect,
        -- Computable only if every part was: one file whose server answers
        -- no reference request leaves the whole answer partial, and saying
        -- otherwise is the over-claim this module exists to stop.
        computable = a.computable and b.computable,
        capped = a.capped or b.capped,
        reason = a.reason or b.reason,
    }
    for _, part in ipairs({ a, b }) do
        for buf in pairs(part.also) do out.also[buf] = true end
    end
    local seen = {}
    for _, part in ipairs({ a, b }) do
        for _, name in ipairs(part.names) do
            if not seen["n" .. name] then
                seen["n" .. name] = true
                out.names[#out.names + 1] = name
            end
        end
        for _, file in ipairs(part.checked) do
            if not seen["f" .. file] then
                seen["f" .. file] = true
                out.checked[#out.checked + 1] = file
            end
        end
    end
    table.sort(out.checked)
    return out
end

-- What the verdict covered, as the tail of a clean verdict about `scope`
-- (the edited file, or the files this call edited).
function M.clause(cl, scope)
    scope = scope or "this file"
    if not cl then
        return (" in %s"):format(scope)
    end
    local n = #cl.checked
    if not cl.computable then
        return (" in %s. Which other files depend on it could not be worked out here (%s), so "
            .. "its importers were not checked; check_project runs the project's own build "
            .. "or check"):format(scope, cl.reason or "no reference information was available")
    end
    if n == 0 then
        return (" in %s, and the server reports no other file using what this edit changed, "
            .. "so there was nothing else to ask"):format(scope)
    end
    return (" in %s or in the %d %s that %s what it changed, listed under checked%s"):format(
        scope, n, plural(n, "file", "files"), plural(n, "uses", "use"),
        cl.capped and ". The closure stopped at that many files, so importers past them "
            .. "were not checked" or "")
end

-- The same, for a call that leaves no buffer to report against: delete_file.
function M.clause_gone(cl)
    if not cl or not cl.computable then
        return (". Which files used this one could not be worked out here (%s), so its "
            .. "importers were not checked; check_project runs the project's own build "
            .. "or check"):format((cl and cl.reason)
            or "no reference information was available")
    end
    local n = #cl.checked
    if n == 0 then
        return ", and the server reports no other file using what this file declared, "
            .. "so there was nothing else to ask"
    end
    return (" in the %d %s that %s what this file declared, listed under checked%s"):format(
        n, plural(n, "file", "files"), plural(n, "used", "used"),
        cl.capped and ". The closure stopped at that many files, so importers past them "
            .. "were not checked" or "")
end

-- The list itself, and what it means. Attached whatever the verdict says, so
-- a reply that does report new errors still states what it looked at.
function M.attach(report, cl)
    if not cl or #cl.checked == 0 then return report end
    report.checked = cl.checked
    report.checked_note = ("the verdict covers these files as well: this call loaded them and "
        .. "waited for their servers, because they use what it changed%s. Files that reach it "
        .. "through a longer chain than that were not followed"):format(
        cl.indirect > 0 and (", %d of them through another file"):format(cl.indirect) or "")
    return report
end

return M
