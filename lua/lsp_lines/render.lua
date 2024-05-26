local M = {}

local HIGHLIGHTS = {
  native = {
    [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualTextError",
    [vim.diagnostic.severity.WARN] = "DiagnosticVirtualTextWarn",
    [vim.diagnostic.severity.INFO] = "DiagnosticVirtualTextInfo",
    [vim.diagnostic.severity.HINT] = "DiagnosticVirtualTextHint",
  },
  coc = {
    [vim.diagnostic.severity.ERROR] = "CocErrorVirtualText",
    [vim.diagnostic.severity.WARN] = "CocWarningVirtualText",
    [vim.diagnostic.severity.INFO] = "CocInfoVirtualText",
    [vim.diagnostic.severity.HINT] = "CocHintVirtualText",
  },
}

-- These don't get copied, do they? We only pass around and compare pointers, right?
local SPACE = "space"
local DIAGNOSTIC = "diagnostic"
local OVERLAP = "overlap"
local BLANK = "blank"

---Returns the distance between two columns in cells.
---
---Some characters (like tabs) take up more than one cell.
---Additionally, inline virtual text can make the distance between two columns larger.
---A diagnostic aligned
---under such characters needs to account for that and add that many spaces to
---its left.
---
---@return integer
local function distance_between_cols(bufnr, lnum, start_col, end_col)
  return vim.api.nvim_buf_call(bufnr, function()
    local s = vim.fn.virtcol({ lnum + 1, start_col })
    local e = vim.fn.virtcol({ lnum + 1, end_col + 1 })
    return e - 1 - s
  end)
end

---Canonicalize a severity
---@param severity any
---@return vim.diagnostic.Severity
local function to_severity(severity)
  if type(severity) == 'string' then
    local s = vim.diagnostic.severity[string.upper(severity)]
    assert(s and type(s) == "integer", string.format('Invalid severity: %s', severity))
    return s
  end
  return severity
end

local function severity_filter(sev)
  local filter
  if type(sev) ~= "table" then
    sev = to_severity(sev)
    filter = function(diag)
      return diag.severity == sev
    end
  elseif sev.max or sev.min then
    local max = to_severity(sev.max) or vim.diagnostic.severity.ERROR
    local min = to_severity(sev.min) or vim.diagnostic.severity.HINT
    filter = function(diag)
      return diag.severity >= max and diag.severity <= min
    end
  else
    local map = {}
    for _, s in ipairs(sev) do
      map[to_severity(s)] = true
    end
    filter = function(diag)
      return map[diag.severity]
    end
  end
  return filter
end

---render diagnostics
---@param namespace number
---@param bufnr number
---@param diagnostics table
---@param opts Opts
---@param source 'native'|'coc'|nil If nil, defaults to 'native'.
function M.show(namespace, bufnr, diagnostics, opts, source)
  local curr_line_opts = opts.virtual_lines.current_line_opts
  local curr_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  if opts.virtual_lines and opts.virtual_lines.severity then
    local filter = severity_filter(opts.virtual_lines.severity)
    if curr_line_opts and curr_line_opts.severity ~= nil then
      -- TODO: this could be more efficient
      local curr_line_filter
      local rest_filter = filter
      if curr_line_opts.severity then
        curr_line_filter = severity_filter(curr_line_opts.severity)
      else
        curr_line_filter = function() return true end
      end
      filter = function(diag)
        local is_curr = diag.end_lnum and (curr_line >= diag.lnum and curr_line <= diag.end_lnum)
            or (curr_line == diag.lnum)
        if is_curr then
          return curr_line_filter(diag)
        else
          return rest_filter(diag)
        end
      end
    end
    diagnostics = vim.tbl_filter(filter, diagnostics)
  end
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end
  vim.validate({
    namespace = { namespace, "n" },
    bufnr = { bufnr, "n" },
    diagnostics = {
      diagnostics,
      vim.islist or vim.tbl_islist,
      "a list of diagnostics",
    },
    opts = { opts, "t", true },
  })

  table.sort(diagnostics, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    else
      return a.col < b.col
    end
  end)

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  if #diagnostics == 0 then
    return
  end
  local highlight_groups = HIGHLIGHTS[source or "native"]

  -- This loop reads line by line, and puts them into stacks with some
  -- extra data, since rendering each line will require understanding what
  -- is beneath it.
  -- TODO: if the virt_line would go off screen then adjust
  local line_stacks = {}
  local prev_lnum = -1
  local prev_col = 0
  for _, diagnostic in ipairs(diagnostics) do
    if line_stacks[diagnostic.lnum] == nil then
      line_stacks[diagnostic.lnum] = {}
    end

    local stack = line_stacks[diagnostic.lnum]

    if diagnostic.lnum ~= prev_lnum then
      table.insert(stack, { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, 0, diagnostic.col)) })
    elseif diagnostic.col ~= prev_col then
      -- Clarification on the magic numbers below:
      -- +1: indexing starting at 0 in one API but at 1 on the other.
      -- -1: for non-first lines, the previous col is already drawn.
      table.insert(
        stack,
        { SPACE, string.rep(" ", distance_between_cols(bufnr, diagnostic.lnum, prev_col + 1, diagnostic.col) - 1) }
      )
    else
      table.insert(stack, { OVERLAP, diagnostic.severity })
    end

    if diagnostic.message:find("^%s*$") then
      table.insert(stack, { BLANK, diagnostic })
    else
      table.insert(stack, { DIAGNOSTIC, diagnostic })
    end

    prev_lnum = diagnostic.lnum
    prev_col = diagnostic.col
  end

  local arrow_width = opts.virtual_lines and opts.virtual_lines.arrow_width or 4
  local arrow = string.rep("─", arrow_width)
  for lnum, lelements in pairs(line_stacks) do
    local dont_highlight_whole_line = opts.virtual_lines and (opts.virtual_lines.highlight_whole_line == false)
    if curr_line_opts and lnum == curr_line then
      dont_highlight_whole_line = (curr_line_opts.highlight_whole_line == false) or dont_highlight_whole_line
    end
    local virt_lines = {}

    -- We read in the order opposite to insertion because the last
    -- diagnostic for a real line, is rendered upstairs from the
    -- second-to-last, and so forth from the rest.
    for i = #lelements, 1, -1 do -- last element goes on top
      if lelements[i][1] == DIAGNOSTIC then
        local diagnostic = lelements[i][2]
        local empty_space_hi
        if dont_highlight_whole_line then
          empty_space_hi = ""
        else
          empty_space_hi = highlight_groups[diagnostic.severity]
        end

        local left = {}
        local overlap = false
        local multi = 0

        -- Iterate the stack for this line to find elements on the left.
        for j = 1, i - 1 do
          local type = lelements[j][1]
          local data = lelements[j][2]
          if type == SPACE then
            if multi == 0 then
              table.insert(left, { data, empty_space_hi })
            else
              table.insert(left, { string.rep("─", data:len()), highlight_groups[diagnostic.severity] })
            end
          elseif type == DIAGNOSTIC then
            -- If an overlap follows this, don't add an extra column.
            if lelements[j + 1][1] ~= OVERLAP then
              table.insert(left, { "│", highlight_groups[data.severity] })
            end
            overlap = false
          elseif type == BLANK then
            if multi == 0 then
              table.insert(left, { "└", highlight_groups[data.severity] })
            else
              table.insert(left, { "┴", highlight_groups[data.severity] })
            end
            multi = multi + 1
          elseif type == OVERLAP then
            overlap = true
          end
        end

        local center_symbol
        if overlap and multi > 0 then
          center_symbol = "┼"
        elseif overlap then
          center_symbol = "├"
        elseif multi > 0 then
          center_symbol = "┴"
        else
          center_symbol = "└"
        end
        -- local center_text =
        local center = {
          { string.format("%s%s ", center_symbol, arrow), highlight_groups[diagnostic.severity] },
        }

        -- TODO: We can draw on the left side if and only if:
        -- a. Is the last one stacked this line.
        -- b. Has enough space on the left.
        -- c. Is just one line.
        -- d. Is not an overlap.

        local msg
        if diagnostic.code then
          msg = string.format("%s: %s", diagnostic.code, diagnostic.message)
        else
          msg = diagnostic.message
        end
        for msg_line in msg:gmatch("([^\n]+)") do
          local vline = {}
          vim.list_extend(vline, left)
          vim.list_extend(vline, center)
          vim.list_extend(vline, { { msg_line, highlight_groups[diagnostic.severity] } })

          table.insert(virt_lines, vline)

          -- Special-case for continuation lines:
          if overlap then
            center = { { "│", highlight_groups[diagnostic.severity] }, { "     ", empty_space_hi } }
          else
            center = { { "      ", empty_space_hi } }
          end
        end
      end
    end

    vim.api.nvim_buf_set_extmark(bufnr, namespace, lnum, 0, { virt_lines = virt_lines })
  end
end

---@param namespace number
---@param bufnr number
function M.hide(namespace, bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
