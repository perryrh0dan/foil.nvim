local M = {}

local uv = vim.loop

local defaults = {
    float = {
        border = "rounded",
        title = "Mass Rename",
        relative = "editor",
        width = 0.6,  -- as fraction of editor width
        height = 0.6, -- as fraction of editor height
        row = 0.2,    -- top offset as fraction
        col = 0.2,    -- left offset as fraction
    },
    -- whether to show only basenames in the buffer while keeping absolute paths under the hood
    show_basename = false,
}

local function cfg()
    M._cfg = M._cfg or defaults
    return M._cfg
end

local function normalize(p)
    if not p or p == "" then return p end
    return vim.fs.normalize(vim.fn.fnamemodify(p, ":p"))
end

local function exists(path)
    local stat = uv.fs_stat(path)
    return stat ~= nil
end

local function is_dir(path)
    local stat = uv.fs_stat(path)
    return stat and stat.type == "directory"
end

local function ensure_parent_dir(path)
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent ~= path and parent ~= "" and not exists(parent) then
        -- Try to create recursively
        vim.fn.mkdir(parent, "p")
    end
end

-- Generate a unique temporary path for cycle-breaking
local function tmp_for(path)
    local base = path .. ".~mr~" .. tostring(math.random(100000, 999999))
    while exists(base) do
        base = path .. ".~mr~" .. tostring(math.random(100000, 999999))
    end
    return base
end

-- Create the floating window + buffer
local function open_float()
    local buf = vim.api.nvim_create_buf(true, false)

    vim.api.nvim_buf_set_name(buf, "foil://list")

    local c = cfg().float
    local cols = vim.o.columns
    local lines = vim.o.lines - vim.o.cmdheight
    local width = math.max(40, math.floor((type(c.width) == "number" and c.width <= 1 and cols * c.width) or c.width))
    local height = math.max(10,
        math.floor((type(c.height) == "number" and c.height <= 1 and lines * c.height) or c.height))
    local row = math.floor((type(c.row) == "number" and c.row <= 1 and lines * c.row) or c.row)
    local col = math.floor((type(c.col) == "number" and c.col <= 1 and cols * c.col) or c.col)

    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("buftype", "acwrite", { buf = buf })
    vim.api.nvim_set_option_value("filetype", "massrename", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

    local win = vim.api.nvim_open_win(buf, true, {
        relative = c.relative,
        width = width,
        height = height,
        row = row,
        col = col,
        border = c.border,
        title = c.title,
    })

    -- Oil-like niceties
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].cursorline = true

    -- q to close
    vim.keymap.set("n", "q", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, nowait = true })

    vim.api.nvim_set_current_win(win)

    return buf, win
end

-- Diff old->new and compute a rename plan (with cycle handling)
local function compute_plan(old_paths, new_paths)
    local ops = {}
    local src_set = {}
    local dst_set = {}
    for i, src in ipairs(old_paths) do
        local dst = new_paths[i]
        if src and dst and src ~= dst then
            ops[#ops + 1] = { src = src, dst = dst }
            src_set[src] = true
            dst_set[dst] = true
        end
    end

    -- Detect conflicts (two entries to same destination)
    local seen_dst = {}
    for _, op in ipairs(ops) do
        if seen_dst[op.dst] then
            return nil, string.format("duplicate destination: %s", op.dst)
        end
        seen_dst[op.dst] = true
    end

    -- Break cycles by renaming to temporary files first if needed
    -- Strategy: if a destination path is also a source in another op and the dest exists,
    -- we stage renames: src -> tmp, then tmp -> dst in second phase.
    local stage1, stage2 = {}, {}
    local src_lookup = {}
    for _, op in ipairs(ops) do src_lookup[op.src] = true end

    for _, op in ipairs(ops) do
        local needs_temp = src_lookup[op.dst] or exists(op.dst)
        if needs_temp then
            local tmp = tmp_for(op.dst)
            stage1[#stage1 + 1] = { src = op.src, dst = tmp, temp = true, final = op.dst }
            stage2[#stage2 + 1] = { src = tmp, dst = op.dst, temp = false }
        else
            stage1[#stage1 + 1] = { src = op.src, dst = op.dst, temp = false }
        end
    end

    return vim.list_extend(stage1, stage2)
end

-- Apply a series of rename operations atomically-ish
local function apply_plan(plan)
    local applied = {}
    for _, op in ipairs(plan) do
        ensure_parent_dir(op.dst)
        local ok, err = uv.fs_rename(op.src, op.dst)
        if not ok then
            -- rollback best-effort
            for i = #applied, 1, -1 do
                local prev = applied[i]
                uv.fs_rename(prev.dst, prev.src)
            end
            return false, string.format("rename failed: %s → %s (%s)", op.src, op.dst, err or "unknown")
        end
        table.insert(applied, op)
    end
    return true
end

-- Populate buffer with paths (and keep originals in b:massrename_orig)
local function populate(buf, paths)
    local show_basename = cfg().show_basename
    local lines = {}
    for _, p in ipairs(paths) do
        if show_basename then
            table.insert(lines, vim.fn.fnamemodify(p, ":t"))
        else
            table.insert(lines, p)
        end
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].massrename_orig = vim.deepcopy(paths)
    vim.b[buf].massrename_show_basename = show_basename
end

local function on_write(buf)
    local orig = vim.b[buf].massrename_orig or {}
    local show_basename = vim.b[buf].massrename_show_basename
    local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local new_paths = {}
    if show_basename then
        for i, base in ipairs(new_lines) do
            local old_abs = orig[i]
            if not old_abs then break end
            local parent = vim.fn.fnamemodify(old_abs, ":h")
            new_paths[i] = normalize(parent .. "/" .. base)
        end
    else
        for i, line in ipairs(new_lines) do
            new_paths[i] = normalize(line)
        end
    end

    for i, np in ipairs(new_paths) do
        if np == nil or np == "" then
            return false, string.format("line %d is empty", i)
        end
        if is_dir(orig[i]) then
            return false, "directories not supported yet"
        end
    end

    local plan, err = compute_plan(orig, new_paths)
    if not plan then return false, err end

    local ok, err2 = apply_plan(plan)
    if not ok then return false, err2 end

    vim.b[buf].massrename_orig = new_paths
    return true
end

function M.open_from_list(paths, opts)
    M._cfg = vim.tbl_deep_extend("force", defaults, opts or {})
    local buf, win = open_float()
    populate(buf, paths)

    -- Apply on :w
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            local ok, err = on_write(buf)
            if not ok then
                vim.api.nvim_buf_call(buf, function()
                    vim.notify("Mass rename failed: " .. tostring(err), vim.log.levels.ERROR)
                end)
            else
                pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })
                vim.notify("Mass rename applied", vim.log.levels.INFO)
            end
        end,
    })

    return buf, win
end

function M.open_from_quickfix(opts)
    local qf = vim.fn.getqflist()
    local files, seen = {}, {}

    for _, item in ipairs(qf) do
        local f = item.text
        if f and f ~= "" then
            f = normalize(f)
            if not seen[f] then
                table.insert(files, f)
                seen[f] = true
            end
        end
    end
    if #files == 0 then
        vim.notify("Quickfix is empty", vim.log.levels.WARN)
        return
    end
    return M.open_from_list(files, opts)
end

function M.open_from_args(opts)
    local args = vim.fn.argv()
    local files, seen = {}, {}
    for _, a in ipairs(args) do
        local f = normalize(a)
        if not seen[f] then
            table.insert(files, f)
            seen[f] = true
        end
    end
    if #files == 0 then
        vim.notify("Arglist is empty", vim.log.levels.WARN)
        return
    end
    return M.open_from_list(files, opts)
end

function M.setup(opts)
    M._cfg = vim.tbl_deep_extend("force", defaults, opts or {})

    vim.api.nvim_create_user_command("FoilQuickfix", function(cmd)
        M.open_from_quickfix(M._cfg)
    end, {})

    vim.api.nvim_create_user_command("FoilArgs", function(cmd)
        M.open_from_args(M._cfg)
    end, {})
end

return M
