local M = {}

local methods = {
  ["textDocument/hover"] = "hoverProvider",
  ["textDocument/definition"] = "definitionProvider",
  ["textDocument/declaration"] = "declarationProvider",
  ["textDocument/references"] = "referencesProvider",
  ["textDocument/typeDefinition"] = "typeDefinitionProvider",
  ["textDocument/implementation"] = "implementationProvider",
  ["textDocument/completion"] = "completionProvider",
  ["textDocument/rename"] = "renameProvider",
}

function M.new(root)
  local api = vim.api
  local native, graph, projection
  local documents, diagnostics, published = {}, {}, {}
  local proxy, dispatch
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.general.positionEncodings = { "utf-8" }
  capabilities.textDocument.completion.completionItem.snippetSupport = false
  capabilities.textDocument.completion.completionItem.insertReplaceSupport = false
  capabilities.textDocument.completion.completionItem.resolveSupport = nil
  capabilities.textDocument.completion.completionList = nil

  local function publish()
    if not dispatch then return end
    local grouped = {}
    for _, entries in pairs(diagnostics) do
      for _, entry in ipairs(entries) do
        local items = grouped[entry.uri] or {}
        items[vim.json.encode(entry.diagnostic, { sort_keys = true })] = entry.diagnostic
        grouped[entry.uri] = items
      end
    end
    for uri in pairs(published) do
      if not grouped[uri] then
        dispatch.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = {} })
      end
    end
    for uri, items in pairs(grouped) do
      dispatch.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = vim.tbl_values(items) })
    end
    published = grouped
  end

  local function diagnostic(_, params, ctx)
    local current = projection
    local doc = documents[params.uri]
    if not (current and current.ready and doc and doc.saved and graph and ctx.client_id == native) then return end
    if params.version and params.version ~= vim.lsp.util.buf_versions[doc.buf] then return end
    local request = vim.tbl_extend("force", params, { revision = current.revision })
    graph:request("ospero/projectDiagnostics", request, function(err, result)
      if err or not result or projection ~= current then return end
      diagnostics[params.uri] = result
      publish()
    end, doc.buf)
  end

  local function start_native(buf)
    return vim.lsp.start({
      name = "ocamllsp-lit",
      cmd = { "opam", "exec", "--", "ocamllsp" },
      cmd_cwd = projection.root,
      root_dir = projection.root,
      capabilities = capabilities,
      get_language_id = function(_, ft) return ft end,
      handlers = { ["textDocument/publishDiagnostics"] = diagnostic },
      on_exit = function(_, _, id)
        vim.schedule(function()
          if native == id then
            native = nil
            diagnostics = {}
            publish()
          end
        end)
      end,
    }, { bufnr = buf })
  end

  local function drop(uri)
    local doc = documents[uri]
    documents[uri], diagnostics[uri] = nil, nil
    vim.api.nvim_buf_delete(doc.buf, { force = true })
  end

  local function update(params, ctx)
    graph = vim.lsp.get_client_by_id(ctx.client_id)
    local became_ready = params.ready and (not projection or not projection.ready)
    projection = params
    for _, uri in ipairs(params.removed) do drop(uri) end
    local function attach(doc)
      if native and vim.lsp.get_client_by_id(native) then
        vim.lsp.buf_attach_client(doc.buf, native)
      else
        native = start_native(doc.buf)
      end
    end
    for _, target in ipairs(params.files) do
      local doc = documents[target.uri]
      if not doc then
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(buf, vim.uri_to_fname(target.uri))
        vim.bo[buf].filetype = target.uri:sub(-4) == ".mli" and "ocaml.interface" or "ocaml"
        doc = { buf = buf }
        documents[target.uri] = doc
      end
      if target.text then
        local lines = vim.split(target.text, "\n", { plain = true })
        local eol = lines[#lines] == ""
        if eol then table.remove(lines) end
        diagnostics[target.uri] = nil
        vim.bo[doc.buf].endofline = eol
        vim.api.nvim_buf_set_lines(doc.buf, 0, -1, false, lines)
        vim.bo[doc.buf].modified = false
      end
      if not target.saved then diagnostics[target.uri] = nil end
      if params.ready and not became_ready then attach(doc) end
      local client = native and vim.lsp.get_client_by_id(native)
      if doc.saved == false and target.saved and client and client.initialized then
        client:notify("textDocument/didSave", { textDocument = { uri = target.uri } })
      end
      doc.saved = target.saved
    end
    if became_ready then
      for _, doc in pairs(documents) do attach(doc) end
    end
    publish()
  end

  local function forward(method, params, done)
    local client = native and vim.lsp.get_client_by_id(native)
    if not (client and client.initialized and client.offset_encoding == "utf-8" and graph and projection) then
      return done(nil, nil)
    end
    local mapper = graph
    local source = vim.uri_to_bufnr(params.textDocument.uri)
    local tick = api.nvim_buf_get_changedtick(source)
    local function latest(route)
      return graph == mapper and projection and route.revision == projection.revision and api.nvim_buf_is_valid(source)
        and tick == api.nvim_buf_get_changedtick(source)
    end
    if not mapper:request("ospero/lookup", params, function(err, route)
      if err or not route then return done(err, nil) end
      local contexts = route.contexts
      if not latest(route) or #contexts == 0
          or (method == "textDocument/completion" and #contexts ~= 1) then
        return done(nil, nil)
      end
      local results, remaining = {}, #contexts
      local function collect(i, failure, result)
        if remaining == 0 then return end
        if failure then
          remaining = 0
          return done(failure, nil)
        end
        results[i] = result or vim.NIL
        remaining = remaining - 1
        if remaining == 0 then
          if not latest(route) then return done(nil, nil) end
          local response = vim.tbl_extend("force", params, { method = method, revision = route.revision, results = results })
          if not mapper:request("ospero/projectResult", response, function(error, result)
            if latest(route) then return done(error, result) end
            done(nil, nil)
          end, source) then done(nil, nil) end
        end
      end
      for i, context in ipairs(contexts) do
        local doc = documents[context.textDocument.uri]
        if not doc or not client:supports_method(method, doc.buf)
            or not client:request(method, vim.tbl_extend("force", params, context), function(failure, result)
              collect(i, failure, result)
            end, doc.buf) then
          collect(i, nil, nil)
        end
      end
    end, source) then done(nil, nil) end
  end

  local function server(dispatchers)
    dispatch = dispatchers
    local closing, serial = false, 0
    local function terminate()
      if closing then return end
      closing = true
      dispatch = nil
      published = {}
      dispatchers.on_exit(0, 0)
    end
    return {
      request = function(method, params, callback, replied)
        serial = serial + 1
        local id = serial
        vim.schedule(function()
          local function done(err, result)
            if closing then return end
            if replied then replied(id) end
            callback(err, result)
          end
          if method == "initialize" then
            local caps = { positionEncoding = "utf-8" }
            for _, key in pairs(methods) do caps[key] = true end
            caps.completionProvider = { triggerCharacters = { ".", "~", "?", "#" } }
            done(nil, { capabilities = caps })
          elseif methods[method] then
            forward(method, params, done)
          else
            done(nil, nil)
          end
        end)
        return true, id
      end,
      notify = function(method)
        if method == "exit" then terminate() end
        return true
      end,
      is_closing = function() return closing end,
      terminate = terminate,
    }
  end

  return {
    update = update,
    attach = function(buf)
      if proxy and vim.lsp.get_client_by_id(proxy) then
        vim.lsp.buf_attach_client(buf, proxy)
      else
        proxy = vim.lsp.start({ name = "ospero-ocaml", cmd = server, root_dir = root }, { bufnr = buf })
      end
    end,
    reset = function(id)
      if not graph or graph.id ~= id then return end
      graph, projection = nil, nil
      for _, uri in ipairs(vim.tbl_keys(documents)) do drop(uri) end
      local client = native and vim.lsp.get_client_by_id(native)
      native = nil
      if client then client:stop() end
      publish()
    end,
  }
end

return M
