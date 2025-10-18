local M = {}

-- Defaults (can be overridden in setup)
M.opts = {
  left_keys = { "a", "s", "d", "f", "g" },
  right_keys = { "h", "j", "k", "l", ";" },
  max_items = 10, -- total MRU items we consider
  border = "rounded",
  winblend = 0,
  zindex = 200,
  padding_h = 3, -- horizontal padding (spaces) inside popup (left + right)
  -- vertical padding (top/bottom). Use top=1, bottom=0 to avoid extra empty space at bottom.
  padding_v_top = 1,
  padding_v_bottom = 0,
  -- Back-compat: if padding_v is provided, it applies to both top and bottom unless the *_top/_bottom overrides are set.
  padding_v = nil,
  min_width = 40,
  highlight = "Visual", -- highlight group for selected cell
  gap_between_cols = 2, -- spaces between left and right column
}

local state = {
  win = nil,
  buf = nil,
  assigned = {}, -- key -> bufnr (only for keys that have buffers)
  rows = {}, -- key -> line (0-based) in popup buffer (content line, not counting border)
  spans = {}, -- key -> {start_col, end_col} (byte indices for highlight on that line)
  paths = {}, -- key -> { rel = "...", fname = "..." }
  selected_key = nil,
  ns = vim.api.nvim_create_namespace "popup-juggler",
  footer_lnum = nil, -- 0-based content line for footer (full path)
  inner_w = nil, -- inner content width (no border)
}

local function close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.assigned = {}
  state.rows = {}
  state.spans = {}
  state.paths = {}
  state.selected_key = nil
  state.footer_lnum = nil
  state.inner_w = nil
end

local function fit_path_to_width(path, width)
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(path) <= width then
    return path
  end

  local shortened = vim.fn.pathshorten(path)
  if vim.fn.strdisplaywidth(shortened) <= width then
    return shortened
  end

  local fname = vim.fn.fnamemodify(path, ":t")
  if vim.fn.strdisplaywidth(fname) <= width then
    return fname
  end

  local ell = "…"
  local avail = math.max(1, width - vim.fn.strdisplaywidth(ell))

  local tail = fname
  while vim.fn.strdisplaywidth(tail) > avail do
    local chars = vim.fn.strchars(tail)
    if chars <= 1 then
      break
    end
    tail = vim.fn.strcharpart(tail, 1)
  end
  return ell .. tail
end

local function recent_buffers()
  local bufs = vim.fn.getbufinfo { buflisted = 1 }
  local filtered = {}
  for _, b in ipairs(bufs) do
    if b.name ~= "" and b.listed == 1 and b.hidden ~= 2 then
      table.insert(filtered, b)
    end
  end
  table.sort(filtered, function(a, b)
    local au = a.lastused or 0
    local bu = b.lastused or 0
    if au == bu then
      return a.bufnr > b.bufnr
    end
    return au > bu
  end)

  local cur = vim.api.nvim_get_current_buf()
  local reordered = {}
  for _, b in ipairs(filtered) do
    if b.bufnr ~= cur then
      table.insert(reordered, b)
    end
  end
  local maxn = math.min(#reordered, M.opts.max_items)
  local out = {}
  for i = 1, maxn do
    out[i] = reordered[i]
  end
  return out
end

local function update_footer()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  if state.footer_lnum == nil then
    return
  end

  local ph = math.max(0, M.opts.padding_h)
  local inner_width = state.inner_w or 0
  local text_width = math.max(0, inner_width - (ph * 2))
  local left_pad = string.rep(" ", ph)
  local right_pad = left_pad

  local content = ""
  if state.selected_key then
    local pinfo = state.paths[state.selected_key]
    if pinfo and pinfo.rel then
      content = pinfo.rel
    end
  end

  local fitted = fit_path_to_width(content, text_width)
  local pad = math.max(0, text_width - vim.fn.strdisplaywidth(fitted))
  local line = left_pad .. fitted .. string.rep(" ", pad) .. right_pad

  vim.api.nvim_buf_set_lines(state.buf, state.footer_lnum, state.footer_lnum + 1, false, { line })
end

local function render(buf, items, col_width, inner_w)
  local left_keys = M.opts.left_keys
  local right_keys = M.opts.right_keys
  local rows = math.max(#left_keys, #right_keys)
  local ph = math.max(0, M.opts.padding_h)

  -- Resolve vertical paddings with backwards compatibility
  local pv_top = M.opts.padding_v_top
  local pv_bottom = M.opts.padding_v_bottom
  if M.opts.padding_v ~= nil then
    pv_top = (M.opts.padding_v_top ~= nil) and pv_top or M.opts.padding_v
    pv_bottom = (M.opts.padding_v_bottom ~= nil) and pv_bottom or M.opts.padding_v
  end
  pv_top = math.max(0, pv_top or 0)
  pv_bottom = math.max(0, pv_bottom or 0)

  local gap = M.opts.gap_between_cols

  local left_items, right_items = {}, {}

  -- Assign items to keys: left column first, then right column
  for i = 1, rows do
    local lk = left_keys[i]
    local rk = right_keys[i]
    local left_idx = i
    local right_idx = #left_keys + i

    local left_it = lk and { key = lk } or nil
    if left_it and items[left_idx] then
      left_it.bufnr = items[left_idx].bufnr
      left_it.name = items[left_idx].name
    end
    table.insert(left_items, left_it)

    local right_it = rk and { key = rk } or nil
    if right_it and items[right_idx] then
      right_it.bufnr = items[right_idx].bufnr
      right_it.name = items[right_idx].name
    end
    table.insert(right_items, right_it)
  end

  -- Reset maps
  state.assigned = {}
  state.rows = {}
  state.spans = {}
  state.paths = {}

  -- Helper to format a cell string (filename only) and return the text + padded cell
  local function cell_text_and_padded(it)
    if not it or not it.key then
      local empty = string.rep(" ", col_width)
      return "", empty
    end
    if not it.name then
      local label = "[" .. it.key .. "]"
      local pad = math.max(0, col_width - vim.fn.strdisplaywidth(label))
      return label, label .. string.rep(" ", pad)
    end
    local rel = vim.fn.fnamemodify(it.name, ":.")
    local fname = vim.fn.fnamemodify(it.name, ":t") -- filename only in the cell
    local fitted = fname
    if vim.fn.strdisplaywidth(fname) > math.max(1, col_width - 4) then
      -- Fit filename if it's too long
      local limit = math.max(1, col_width - 4)
      -- cheap left-ellipsis for long filenames
      local ell = "…"
      local avail = math.max(1, limit - vim.fn.strdisplaywidth(ell))
      local tail = fname
      while vim.fn.strdisplaywidth(tail) > avail do
        if vim.fn.strchars(tail) <= 1 then
          break
        end
        tail = vim.fn.strcharpart(tail, 1)
      end
      fitted = ell .. tail
    end
    local label = "[" .. it.key .. "] " .. fitted
    local pad = math.max(0, col_width - vim.fn.strdisplaywidth(label))
    -- Save mappings for footer/open action
    state.paths[it.key] = { rel = rel, fname = fname }
    state.assigned[it.key] = it.bufnr
    return label, label .. string.rep(" ", pad)
  end

  local lines = {}

  -- Top vertical padding
  for _ = 1, pv_top do
    table.insert(lines, "")
  end

  -- Build content lines with left/right padding + two cells + right padding
  for i = 1, rows do
    local L = left_items[i]
    local R = right_items[i]

    local ltext, lcell = cell_text_and_padded(L)
    local rtext, rcell = cell_text_and_padded(R)

    local left_pad = string.rep(" ", ph)
    local between = string.rep(" ", gap)
    local right_pad = string.rep(" ", ph)

    local line = left_pad .. lcell .. between .. rcell .. right_pad
    table.insert(lines, line)

    local lstart = ph -- byte offset where left cell text starts
    local rstart = ph + #lcell + #between -- byte offset for right cell text starts

    local lline = pv_top + (i - 1) -- 0-based content line number

    if L and L.key then
      state.rows[L.key] = lline
      local lend = lstart + #ltext
      state.spans[L.key] = { start_col = lstart, end_col = lend }
    end

    if R and R.key then
      state.rows[R.key] = lline
      local rend = rstart + #rtext
      state.spans[R.key] = { start_col = rstart, end_col = rend }
    end
  end

  -- Blank line before footer
  table.insert(lines, "")

  -- Footer line: full path (rel to cwd) for selected key (initially blank)
  state.footer_lnum = pv_top + rows + 1
  local footer_left = string.rep(" ", ph)
  local footer_right = footer_left
  local text_width = math.max(0, inner_w - (ph * 2))
  local footer_line = footer_left .. string.rep(" ", text_width) .. footer_right
  -- table.insert(lines, footer_line)
  --
  -- -- Bottom vertical padding (default 0 to avoid extra empty space)
  -- for _ = 1, pv_bottom do
  --   table.insert(lines, "")
  -- end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function apply_selection_highlight()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
  local key = state.selected_key
  if key then
    local lnum = state.rows[key]
    local span = state.spans[key]
    if lnum and span then
      vim.api.nvim_buf_add_highlight(
        state.buf,
        state.ns,
        M.opts.highlight,
        lnum,
        span.start_col,
        span.end_col
      )
    end
  end

  update_footer()
end

local function open_popup(items)
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }

  local rows = math.max(#M.opts.left_keys, #M.opts.right_keys)
  local ph = math.max(0, M.opts.padding_h)
  local gap = M.opts.gap_between_cols

  local pv_top = M.opts.padding_v_top
  local pv_bottom = M.opts.padding_v_bottom
  if M.opts.padding_v ~= nil then
    pv_top = (M.opts.padding_v_top ~= nil) and pv_top or M.opts.padding_v
    pv_bottom = (M.opts.padding_v_bottom ~= nil) and pv_bottom or M.opts.padding_v
  end
  pv_top = math.max(0, pv_top or 0)
  pv_bottom = math.max(0, pv_bottom or 0)

  local target_inner_w = math.max(M.opts.min_width, math.floor(ui.width * 0.8))
  local available_for_cols = target_inner_w - (ph * 2) - gap
  if available_for_cols < 4 then
    available_for_cols = 4
  end
  local col_width = math.floor(available_for_cols / 2)
  if col_width < 10 then
    col_width = 10
  end

  local inner_h = pv_top + rows + 1 + pv_bottom

  local inner_w = ph + col_width + gap + col_width + ph
  state.inner_w = inner_w

  local win_w = math.min(inner_w + 2, ui.width - 2)
  local win_h = math.min(inner_h + 2, ui.height - 2)

  local row = math.max(0, math.floor((ui.height - win_h) / 2))
  local col = math.max(0, math.floor((ui.width - win_w) / 2))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_option(buf, "filetype", "LustyPopupJuggler")
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = win_w,
    height = win_h,
    row = row,
    col = col,
    style = "minimal",
    border = M.opts.border,
    zindex = M.opts.zindex,
  })

  vim.api.nvim_win_set_option(win, "winblend", M.opts.winblend)

  render(buf, items, col_width, inner_w)

  local function map(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end

  local mapped = {}
  for _, key in ipairs(M.opts.left_keys) do
    mapped[key] = true
  end
  for _, key in ipairs(M.opts.right_keys) do
    mapped[key] = true
  end

  for key, _ in pairs(mapped) do
    map(key, function()
      if state.selected_key == key then
        local target = state.assigned[key]
        if target and vim.api.nvim_buf_is_valid(target) then
          close()
          vim.api.nvim_set_current_buf(target)
          return
        end
      else
        state.selected_key = key
        apply_selection_highlight()
      end
    end)
  end

  map("<Esc>", close)
  map("q", close)
  map("<C-c>", close)

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = false

  state.win = win
  state.buf = buf
  apply_selection_highlight()
end

-- Public: open the popup
function M.open()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    close()
  end
  local items = recent_buffers()
  open_popup(items)
end

-- Setup: register user command and optional mapping
function M.setup(opts)
  M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

return M
