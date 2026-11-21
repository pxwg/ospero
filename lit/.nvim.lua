local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
dofile(root .. "/nvim/init.lua")(vim.uv.fs_realpath(root))
