local decorated = setmetatable({}, { __mode = "k" })
local query_text

-- Keep Org's ordinary link rules. The project owns the spelling of card links,
-- including their delimiters, in each window independently.
vim.treesitter.query.add_directive("ospero-host-conceal!", function(match, _, buf, predicate, metadata)
  local nodes = match[predicate[2]]
  local node = type(nodes) == "table" and nodes[1] or nodes
  while node and node:type() ~= "link_desc" and node:type() ~= "link" do
    node = node:parent()
  end
  local url = node and node:field("url")[1]
  if url then
    local text = vim.treesitter.get_node_text(url, buf)
    if text:match("^id:") or text:match("^include:") then return end
  end
  local id = predicate[3]
  if id then
    metadata[id] = metadata[id] or {}
    metadata[id].conceal = ""
  else
    metadata.conceal = ""
  end
end, { force = true, all = true })

return function(buf)
  local highlighter = vim.treesitter.highlighter
  local current = highlighter.active[buf]
  if not current or decorated[current] then return end
  if not query_text then
    local parts = {}
    for _, file in ipairs(vim.treesitter.query.get_files("org", "highlights")) do
      local text = table.concat(vim.fn.readfile(file), "\n")
      text = text:gsub('(@_link_close%s+)%(#set! conceal ""%)', '%1(#ospero-host-conceal! @_link_open)')
      text = text:gsub('%(#set! @_link_url conceal ""%)', '(#ospero-host-conceal! @_link_url @_link_url)')
      parts[#parts + 1] = text
    end
    query_text = table.concat(parts, "\n")
  end
  if query_text == "" then return end
  local tree = current.tree
  current:destroy()
  decorated[highlighter.new(tree, { queries = { org = query_text } })] = true
end
