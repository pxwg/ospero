local M = {}
local surfaces, spans, free = {}, {}, {}
local source_ns = vim.api.nvim_create_namespace("")

local function signature(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    local hl = type(chunk[2]) == "table" and table.concat(chunk[2], ",") or chunk[2]
    parts[#parts + 1] = chunk[1] .. "\0" .. hl
  end
  return table.concat(parts, "\1")
end

local function remove(surface, mark)
  if vim.api.nvim_buf_is_valid(surface.buf) then
    vim.api.nvim_buf_del_extmark(surface.buf, surface.ns, mark.conceal)
    vim.api.nvim_buf_del_extmark(surface.buf, surface.ns, mark.text)
  end
end

local function reconcile(surface, desired)
  -- Read actual positions: Neovim already moved surviving marks with text edits.
  local existing = {}
  for _, mark in pairs(surface.marks) do
    local a = vim.api.nvim_buf_get_extmark_by_id(surface.buf, surface.ns, mark.conceal, { details = true })
    local b = vim.api.nvim_buf_get_extmark_by_id(surface.buf, surface.ns, mark.text, {})
    if #a > 0 and #b > 0 and a[3].end_row == a[1] and b[1] == a[1] and b[2] == a[3].end_col then
      local key = a[1] .. ":" .. a[2] .. ":" .. b[2]
      if existing[key] then
        remove(surface, existing[key])
      end
      existing[key] = mark
    else
      remove(surface, mark)
    end
  end
  local next_marks = {}
  for key, span in pairs(desired) do
    local mark = existing[key]
    existing[key] = nil
    if not mark then
      mark = {
        conceal = vim.api.nvim_buf_set_extmark(surface.buf, surface.ns, span.row, span.col, {
          end_col = span.finish,
          end_right_gravity = false,
          conceal = "",
          priority = 250,
        }),
      }
    end
    local sig = signature(span.chunks)
    if mark.sig ~= sig then
      mark.text = vim.api.nvim_buf_set_extmark(surface.buf, surface.ns, span.row, span.finish, {
        id = mark.text,
        right_gravity = false,
        virt_text = span.chunks,
        virt_text_pos = "inline",
        hl_mode = "combine",
      })
      mark.sig = sig
    end
    next_marks[key] = mark
  end
  for _, mark in pairs(existing) do
    remove(surface, mark)
  end
  surface.marks = next_marks
end

-- Window-scoped namespaces cannot be deleted, so closed windows return theirs to a pool.
local function release(win, surface)
  if vim.api.nvim_buf_is_valid(surface.buf) then
    vim.api.nvim_buf_clear_namespace(surface.buf, surface.ns, 0, -1)
  end
  surfaces[win] = nil
  free[#free + 1] = surface.ns
end

local function acquire(win, buf)
  local ns = table.remove(free) or vim.api.nvim_create_namespace("")
  vim.api.nvim__ns_set(ns, { wins = { win } })
  surfaces[win] = { ns = ns, buf = buf, marks = {} }
  return surfaces[win]
end

local function rows_of(buf)
  local snapshot = spans[buf]
  if not snapshot or not vim.api.nvim_buf_is_loaded(buf) then
    return nil
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if snapshot.tick ~= tick then
    -- Keep unchanged links visible while the server processes the edit.
    local rows = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, source_ns, 0, -1, { details = true })) do
      local id, row, col, range = unpack(mark)
      local item = snapshot.items[id]
      if row == range.end_row then
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        if line and line:sub(col + 1, range.end_col) == item.source then
          rows[row] = rows[row] or {}
          table.insert(rows[row], { col = col, finish = range.end_col, text = item.text })
        end
      end
    end
    snapshot.tick, snapshot.rows = tick, rows
  end
  return snapshot.rows
end

function M.redraw()
  for win, surface in pairs(surfaces) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= surface.buf then
      release(win, surface)
    end
  end

  local focused = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    local rows = vim.wo[win].conceallevel >= 2 and rows_of(buf)
    local desired = {}
    if rows then
      local cursor = win == focused and vim.api.nvim_win_get_cursor(win)
      for row, line in pairs(rows) do
        for _, span in ipairs(line) do
          -- A reference is one object: the cursor on its first byte selects it
          -- with the title shown; only moving inside reveals the source.
          local inside = cursor and cursor[1] - 1 == row and cursor[2] > span.col and cursor[2] < span.finish
          if not inside then
            desired[row .. ":" .. span.col .. ":" .. span.finish] = {
              row = row,
              col = span.col,
              finish = span.finish,
              chunks = { { span.text, "@markup.link" } },
            }
          end
        end
      end
      if not surfaces[win] then
        acquire(win, buf)
      end
    end
    if surfaces[win] then
      reconcile(surfaces[win], desired)
    end
  end
end

function M.update(buf, items)
  if not spans[buf] then
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        if not spans[buf] then
          return true
        end
        vim.schedule(M.redraw)
      end,
    })
  end
  vim.api.nvim_buf_clear_namespace(buf, source_ns, 0, -1)
  local tracked = {}
  for _, item in ipairs(items) do
    local start, finish = item.range.start, item.range["end"]
    local line = vim.api.nvim_buf_get_lines(buf, start.line, start.line + 1, false)[1]
    if start.line == finish.line and line and line:sub(start.character + 1, finish.character) == item.source then
      local id = vim.api.nvim_buf_set_extmark(buf, source_ns, start.line, start.character, {
        end_col = finish.character,
        end_right_gravity = false,
      })
      tracked[id] = { source = item.source, text = "[" .. item.label .. "]" }
    end
  end
  spans[buf] = { items = tracked }
  M.redraw()
end

function M.clear(buf)
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_clear_namespace(buf, source_ns, 0, -1)
  end
  spans[buf] = nil
  M.redraw()
end

return M
