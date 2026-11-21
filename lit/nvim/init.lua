return function(root)
  local group = vim.api.nvim_create_augroup("OsperoLit:" .. root, { clear = true })
  local repo = vim.fs.dirname(root)
  local module = "ospero-lit.titles:" .. root
  local titles = package.loaded[module] or dofile(root .. "/nvim/titles.lua")
  package.loaded[module] = titles
  local org_module = "ospero-lit.org:" .. root
  local org_highlights = package.loaded[org_module] or dofile(root .. "/nvim/org.lua")
  package.loaded[org_module] = org_highlights
  local notes = root .. "/notes"
  local function belongs(buf)
    local file = vim.api.nvim_buf_get_name(buf)
    return vim.bo[buf].buftype == ""
      and (file == root .. "/index.org" or (vim.startswith(file, notes .. "/") and vim.endswith(file, ".org")))
  end

  local function new_card()
    vim.ui.input({ prompt = "文件名: " }, function(name)
      name = vim.trim(name or ""):gsub("%.org$", "")
      if name == "" then
        return
      end
      -- The file stem is also a card ID, so it must match the reader’s ID syntax.
      if not name:match("^[A-Za-z0-9_.-]+$") or name == "." or name == ".." then
        return vim.notify(
          "文件名只能使用英文字母、数字、点、下划线和连字符，且不能是 . 或 ..",
          vim.log.levels.ERROR
        )
      end
      vim.ui.input({ prompt = "标题: " }, function(title)
        title = vim.trim(title or "")
        if title == "" then
          return
        end
        if title:find("[\r\n]") then
          return vim.notify("标题必须为单行", vim.log.levels.ERROR)
        end
        local file = notes .. "/" .. name .. ".org"
        local text = ("* %s\n:PROPERTIES:\n:ID: %s\n:END:\n\n"):format(title, name)
        local fd, err = vim.uv.fs_open(file, "wx", 438)
        if not fd then
          return vim.notify(err, vim.log.levels.ERROR)
        end
        local written, write_err = vim.uv.fs_write(fd, text, 0)
        local closed, close_err = vim.uv.fs_close(fd)
        if written ~= #text or not closed then
          vim.uv.fs_unlink(file)
          return vim.notify(write_err or close_err or "未能写入完整卡片", vim.log.levels.ERROR)
        end
        vim.cmd.edit({ args = { file } })
        vim.api.nvim_win_set_cursor(0, { 5, 0 })
      end)
    end)
  end

  local function attach(buf)
    if not belongs(buf) then
      return
    end
    vim.api.nvim_buf_create_user_command(buf, "LitNew", new_card, { force = true })
    vim.keymap.set("n", "<leader>zn", new_card, { buffer = buf, desc = "新建文学卡片" })
    vim.schedule(function()
      if vim.api.nvim_buf_is_loaded(buf) then
        org_highlights(buf)
      end
    end)
    local client = vim.lsp.start({
      name = "ospero-lit",
      root_dir = root,
      cmd = {
        "opam",
        "exec",
        "--",
        "dune",
        "exec",
        "--root",
        repo,
        "--no-print-directory",
        "./lit/nvim/lit_lsp.exe",
        "--",
        root,
      },
      get_language_id = function()
        return "org"
      end,
      handlers = {
        ["ospero/titles"] = function(_, params)
          local target = vim.uri_to_bufnr(params.uri)
          if vim.api.nvim_buf_is_loaded(target) and vim.lsp.util.buf_versions[target] == params.version then
            titles.update(target, params.spans)
          end
        end,
      },
    }, { bufnr = buf })
    if not client then
      return
    end
    local function map(key, action, desc)
      vim.keymap.set("n", key, action, { buffer = buf, desc = desc })
    end
    map("K", vim.lsp.buf.hover, "查看卡片标题与 ID")
    map("zf", function()
      local server = vim.lsp.get_client_by_id(client)
      if not server then
        return
      end
      server:request("workspace/symbol", { query = "" }, function(err, symbols)
        if err then
          return vim.notify(err.message, vim.log.levels.ERROR)
        end
        local items = {}
        for _, symbol in ipairs(symbols or {}) do
          if symbol.kind == vim.lsp.protocol.SymbolKind.Object then
            local loc = symbol.location
            local start = loc.range.start
            items[#items + 1] = {
              text = symbol.name .. "  " .. symbol.containerName,
              file = vim.uri_to_fname(loc.uri),
              pos = { start.line + 1, start.character },
            }
          end
        end
        require("snacks").picker.pick({
          title = "文学卡片",
          items = items,
          format = "text",
          preview = "file",
        })
      end, buf)
    end, "搜索文学卡片")
    local function command(name, argv, done)
      vim.api.nvim_buf_create_user_command(buf, name, function()
        vim.system(
          argv,
          { cwd = root, text = true },
          vim.schedule_wrap(function(result)
            if result.code == 0 then
              done()
            else
              vim.notify(result.stderr, vim.log.levels.ERROR)
            end
          end)
        )
      end, { force = true })
    end
    command("LitTangle", { "python3", root .. "/seed.py", "tangle" }, function()
      vim.notify("已生成 " .. root .. "/out/")
    end)
    command("LitWeave", { "emacs", "-Q", "--batch", "-l", root .. "/reader/export.el" }, function()
      vim.ui.open(root .. "/index.html")
    end)
  end

  local function configure_window()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    if belongs(buf) then
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
          vim.wo[win].conceallevel = 2
          vim.wo[win].concealcursor = "nvic"
          org_highlights(buf)
        end
      end)
    end
  end
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    pattern = "*.org",
    callback = function(e)
      attach(e.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, { group = group, callback = configure_window })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "ModeChanged", "WinEnter", "WinClosed" }, {
    group = group,
    callback = function()
      vim.schedule(titles.redraw)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "conceallevel", "concealcursor" },
    callback = function()
      vim.schedule(titles.redraw)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    callback = function(e)
      if belongs(e.buf) then
        titles.clear(e.buf)
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      attach(buf)
    end
  end
  configure_window()
end
