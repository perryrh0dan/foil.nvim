local M = {}

local uv = vim.loop

local defaults = {
    float = {
        border = "rounded",
        relative = "editor",
        width = 0.8,
        height = 0.8,
        row = 0.1,
        col = 0.1,
    },
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

local function ensure_parent_dir(path)
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent ~= path and parent ~= "" and not exists(parent) then
        vim.fn.mkdir(parent, "p")
    end
end

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
    vim.api.nvim_set_option_value("filetype", "foil", { buf = buf })
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })

    local win = vim.api.nvim_open_win(buf, true, {
        relative = c.relative,
        width = width,
        height = height,
        row = row,
        col = col,
        border = c.border,
    })

    vim.api.nvim_set_option_value("wrap", false, { scope = "local", win = win })
    vim.api.nvim_set_option_value("conceallevel", 3, { scope = "local", win = win })
    vim.api.nvim_set_option_value("concealcursor", "nvic", { scope = "local", win = win })
    vim.api.nvim_set_option_value("number", false, { scope = "local", win = win })
    vim.api.nvim_set_option_value("relativenumber", false, { scope = "local", win = win })
    vim.api.nvim_set_option_value("signcolumn", "no", { scope = "local", win = win })
    vim.api.nvim_set_option_value("cursorline", true, { scope = "local", win = win })

    vim.keymap.set("n", "q", function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end, { buffer = buf, nowait = true })

    vim.api.nvim_set_current_win(win)

    return buf, win
end

local function compute_plan(old_entries, new_entries)
    local id_count = {}
    for _, item in ipairs(new_entries) do
        if item.id then
            id_count[item.id] = (id_count[item.id] or 0) + 1
        end
    end

    local changes = {}
    local processed_ids = {}

    for _, item in ipairs(new_entries) do
        if item.id and not processed_ids[item.id] then
            processed_ids[item.id] = true

            local lines = {}
            for _, c in ipairs(new_entries) do
                if c.id == item.id then table.insert(lines, c) end
            end

            local orig = nil
            for _, o in ipairs(old_entries) do
                if o.id == item.id then
                    orig = o; break
                end
            end

            if orig then
                if #lines == 1 then
                    local c = lines[1]
                    if c.path == orig.path then
                        table.insert(changes, { change = "unchanged", src = orig.path, des = c.path })
                    else
                        table.insert(changes, { change = "moved", src = orig.path, des = c.path })
                    end
                else
                    table.insert(changes, { change = "moved", src = orig.path, des = lines[1].path })
                    for i = 2, #lines do
                        table.insert(changes, { change = "copied", src = orig.path, des = lines[i].path })
                    end
                end
            else
                for _, c in ipairs(lines) do
                    table.insert(changes, { change = "new", src = nil, des = c.path })
                end
            end
        elseif not item.id then
            table.insert(changes, { change = "new", src = nil, des = item.path })
        end
    end

    -- Detect deleted items
    for _, o in ipairs(old_entries) do
        local exists = false
        for _, c in ipairs(new_entries) do
            if c.id == o.id then
                exists = true; break
            end
        end
        if not exists then
            table.insert(changes, { change = "deleted", src = o.path, des = nil })
        end
    end

    local priority = { copied = 1, moved = 2, deleted = 3, new = 0, unchanged = 0 }

    table.sort(changes, function(a, b)
        return (priority[a.change] or 0) < (priority[b.change] or 0)
    end)

    return changes
end

local function copy_file(src, dest)
    local src_fd = uv.fs_open(src, "r", 438) -- 438 = 0666
    if not src_fd then return end

    local stat = uv.fs_fstat(src_fd)
    if not stat then
        uv.fs_close(src_fd)
        return
    end

    local data = uv.fs_read(src_fd, stat.size, 0)
    uv.fs_close(src_fd)

    local dest_fd = uv.fs_open(dest, "w", stat.mode)
    uv.fs_write(dest_fd, data, 0)
    uv.fs_close(dest_fd)
end

local function apply_plan(plan)
    local applied = {}
    for _, op in ipairs(plan) do
        vim.print(op)
        if op.change == 'moved' then
            ensure_parent_dir(op.des)
            local ok, err = uv.fs_rename(op.src, op.des)
            if not ok then
                -- rollback best-effort
                for i = #applied, 1, -1 do
                    local prev = applied[i]
                    uv.fs_rename(prev.des, prev.src)
                end
                return false, string.format("rename failed: %s → %s (%s)", op.src, op.des, err or "unknown")
            end
        elseif op.change == 'copied' then
            copy_file(op.src, op.des)
        elseif op.change == 'delete' then
            local ok, err = uv.fs_unlink(op.src)
            if not ok then
                print("Failed to delete:", err)
            end
        end

        table.insert(applied, op)
    end
    return true
end

local function populate(buf, paths)
    local lines = {}
    for _, p in ipairs(paths) do
        -- Prepend hidden ID
        table.insert(lines, "/" .. p.id .. " " .. p.path)
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.b[buf].foil_orig = vim.deepcopy(paths)
end

local function on_write(buf)
    local orig = vim.b[buf].foil_orig or {}
    local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local new_entries = {}
    for _, line in ipairs(new_lines) do
        local id, path = line:match("^/(%d+)%s+(.*)")
        table.insert(new_entries, { id = id, path = normalize(path) })
    end

    vim.print(new_entries)

    for i, np in ipairs(new_entries) do
        if np.path == nil or np.path == "" then
            return false, string.format("line %d is empty", i)
        end
    end

    local plan, err = compute_plan(orig, new_entries)
    if not plan then return false, err end

    local ok, err2 = apply_plan(plan)
    if not ok then return false, err2 end

    vim.b[buf].foil_orig = new_entries
    return true
end

function M.open(paths, opts)
    local entries = {}
    for _, p in ipairs(paths) do
        local id = tostring(math.random(1e9))
        table.insert(entries, { id = id, path = p })
    end

    M._cfg = vim.tbl_deep_extend("force", defaults, opts or {})
    local buf, win = open_float()
    populate(buf, entries)

    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = buf })

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

    vim.api.nvim_create_autocmd({ "BufLeave", "WinClosed" }, {
        buffer = buf,
        once = true,
        callback = function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
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
    return M.open(files, opts)
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
    return M.open(files, opts)
end

function M.setup(opts)
    M._cfg = vim.tbl_deep_extend("force", defaults, opts or {})

    vim.api.nvim_create_user_command("FoilQuickfix", function()
        M.open_from_quickfix(M._cfg)
    end, {})

    vim.api.nvim_create_user_command("FoilArgs", function()
        M.open_from_args(M._cfg)
    end, {})
end

return M
