local api = vim.api
local fixture, root = arg[1], arg[2]
local shared = fixture .. "/notes/shared.typ"
local target = fixture .. "/notes/target.typ"
local function client(name, buf)
  return vim.lsp.get_clients({ name = name, bufnr = buf })[1]
end

local function at(buf, fragment, delta, first)
  for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local col = line:find(fragment, 1, true)
    if col and (not first or i >= first) then
      return { line = i - 1, character = col - 1 + (delta or 0) }
    end
  end
  error("Missing fixture text: " .. fragment)
end

local function ready(buf)
  return vim.wait(12000, function()
    local native, proxy = client("ocamllsp-lit"), client("ospero-ocaml", buf)
    return native and native.initialized and proxy and proxy.initialized
  end, 20)
end

local function main()
  vim.cmd.edit(shared)
  dofile(root .. "/nvim/init.lua")(fixture)
  local buf = api.nvim_get_current_buf()
  assert(ready(buf), "The native OCaml client did not initialize")
  local function request(method, position, extra, name, from)
    from = from or buf
    local params = vim.tbl_extend("force", { textDocument = { uri = vim.uri_from_bufnr(from) },
      position = position }, extra or {})
    local response = client(name or "ospero-ocaml", from):request_sync("textDocument/" .. method, params, 6000, from)
    return assert(response, "LSP timeout for " .. method)
  end

  local native = client("ocamllsp-lit")
  local hidden = vim.tbl_keys(native.attached_buffers)
  assert(#hidden == 2, vim.inspect(hidden))
  local ticks = vim.tbl_map(api.nvim_buf_get_changedtick, hidden)
  api.nvim_buf_set_lines(buf, 1, 2, false, { "More prose." })
  assert(client("ospero-lit", buf):request_sync("ospero/lookup", {
    textDocument = { uri = vim.uri_from_bufnr(buf) }, position = at(buf, "= x", 2),
  }, 6000, buf).result)
  assert(vim.deep_equal(ticks, vim.tbl_map(api.nvim_buf_get_changedtick, hidden)))

  local use = at(buf, "= x", 2)
  local hover = request("hover", use).result.contents.value
  assert(hover:find("int") and hover:find("string") and select(2, hover:gsub("target.typ:", "")) == 2, hover)
  local defs = request("definition", use).result
  assert(#defs == 2 and defs[1].uri == vim.uri_from_fname(target) and defs[2].uri == defs[1].uri, vim.inspect(defs))
  local conflict = request("rename", use, { newName = "origin" })
  assert(conflict.err and conflict.err.message:find("single change"), vim.inspect(conflict))
  local rename = request("rename", at(buf, "value ="), { newName = "amount" }).result.documentChanges
  assert(#rename == 1 and #rename[1].edits == 2 and rename[1].textDocument.uri == vim.uri_from_fname(shared))
  assert(vim.deep_equal(rename[1].edits[1].range.start, at(buf, "value =")))
  local card = request("definition", at(buf, "@targets", 2), nil, "ospero-lit").result
  assert(card[1].uri == vim.uri_from_fname(target), vim.inspect(card))

  local first = at(buf, "result = x")
  local second = at(buf, "foo = value")
  api.nvim_buf_set_lines(buf, first.line, first.line + 1, false, { "  let result = x + 1" })
  api.nvim_buf_set_lines(buf, second.line, second.line + 1, false, { '  let foo = let _ = "é" in String.len' })
  local items = request("completion", at(buf, "String.len", 10, second.line + 1)).result.items
  assert(vim.iter(items):any(function(item)
    return item.label == "length" and vim.deep_equal(item.textEdit.range.start, at(buf, "String.len", 7, second.line + 1))
  end), vim.inspect(items))
  vim.cmd.write()
  assert(vim.wait(10000, function()
    return vim.iter(vim.diagnostic.get(buf)):any(function(item)
      return item.source == "ocamllsp" and item.lnum == use.line and item.col == use.character
    end)
  end), vim.inspect(vim.diagnostic.get(buf)))

  vim.cmd.edit(target)
  local target_buf = api.nvim_get_current_buf()
  assert(ready(target_buf))
  local cross = request("definition", at(target_buf, "Provider.provided", 9), nil, nil, target_buf).result
  assert(#cross == 1 and cross[1].uri == vim.uri_from_fname(shared), vim.inspect(cross))
  assert(vim.deep_equal(cross[1].range.start, at(buf, "provided =")))
  native:stop()
  assert(vim.wait(5000, function() return not vim.lsp.get_client_by_id(native.id) end))
  card = request("definition", at(buf, "@targets", 2), nil, "ospero-lit").result
  assert(card[1].uri == vim.uri_from_fname(target))
end

local ok, error_message = xpcall(main, debug.traceback)
if not ok then
  vim.api.nvim_err_writeln(error_message)
  vim.cmd.cquit()
else
  vim.cmd.qa({ bang = true })
end
