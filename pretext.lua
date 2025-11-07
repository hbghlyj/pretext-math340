-- This is a PreTeXt custom writer for pandoc,
-- based loosely on the JATS custom writter: https://github.com/mfenner/pandoc-jats. 
--
-- Invoke with: pandoc -t pretext.lua
--
-- Note:  you need not have lua installed on your system to use this
-- custom writer.  However, if you do have lua installed, you can
-- use it to test changes to the script.  'lua pretext.lua' will
-- produce informative error messages if your code contains
-- syntax errors.

local pipe = pandoc.pipe

local function shell_quote(str)
  local quoted = "'" .. tostring(str):gsub("'", "'\\''") .. "'"
  return quoted
end

local script_path
do
  local info = debug.getinfo(1, "S")
  if info and info.source then
    local path = info.source:match("^@(.*)$")
    if path and path ~= "" then
      if not path:match("^/") then
        local get_cwd = pandoc and pandoc.system and pandoc.system.get_working_directory
        local cwd = get_cwd and get_cwd()
        if cwd and cwd ~= "" then
          path = cwd .. "/" .. path
        end
      end
      script_path = path
    end
  end
end
-- local stringify = (require "pandoc.utils").stringify
-- local utils = require 'pandoc.utils'

-- The global variable PANDOC_DOCUMENT contains the full AST of
-- the document which is going to be written. It can be used to
-- configure the writer.
-- local meta = PANDOC_DOCUMENT.meta

-- global variable to keep track of indent level:
indents = 1

--We define the section names that correspond to the different levels.
sectionNames = {"section", "subsection", "subsubsection", "paragraphs", "paragraphs", "paragraphs"}
--sectionBuffer will be a stack that hold the current open divisions
sectionBuffer = {}

-- Helper utilities for custom rendering
local function trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize_identifier(value)
  if not value or value == "" then
    return ""
  end
  local sanitized = tostring(value)
  sanitized = sanitized:gsub("\\", "/")
  sanitized = sanitized:gsub("^%./+", "")
  sanitized = sanitized:gsub("%.tex$", "")
  sanitized = sanitized:gsub("[/\\]+", "-")
  sanitized = sanitized:gsub("%s+", "-")
  sanitized = sanitized:gsub("[^%w_%.:-]", "-")
  sanitized = sanitized:gsub("-+", "-")
  sanitized = sanitized:gsub("^[-%.:]+", "")
  sanitized = sanitized:gsub("^source[-_]?", "")
  if sanitized == "" or sanitized:match("^[^A-Za-z_]") then
    sanitized = "doc-" .. sanitized
    sanitized = sanitized:gsub("[^%w_%.:-]", "-")
    sanitized = sanitized:gsub("-+", "-")
    sanitized = sanitized:gsub("^[-%.:]+", "")
    if sanitized == "" then
      sanitized = "doc"
    end
  end
  return sanitized
end


local function convert_scale_macros(text)
  local replacements = 0
  local parts = {}
  local pos = 1
  local len = #text
  while pos <= len do
    local start_pos, end_pos = text:find("\\Scale", pos, true)
    if not start_pos then
      table.insert(parts, text:sub(pos))
      break
    end
    table.insert(parts, text:sub(pos, start_pos - 1))
    local cursor = end_pos + 1
    while cursor <= len and text:sub(cursor, cursor):match("%s") do
      cursor = cursor + 1
    end
    local scale = "4"
    if cursor <= len and text:sub(cursor, cursor) == "[" then
      local depth = 1
      local j = cursor + 1
      while j <= len and depth > 0 do
        local ch = text:sub(j, j)
        if ch == "[" then
          depth = depth + 1
        elseif ch == "]" then
          depth = depth - 1
        end
        j = j + 1
      end
      if depth == 0 then
        local raw_scale = trim(text:sub(cursor + 1, j - 2))
        if raw_scale ~= "" then
          scale = raw_scale
        end
        cursor = j
        while cursor <= len and text:sub(cursor, cursor):match("%s") do
          cursor = cursor + 1
        end
      else
        local fallback_end = math.max(cursor - 1, start_pos)
        table.insert(parts, text:sub(start_pos, fallback_end))
        pos = fallback_end + 1
        goto continue_loop
      end
    end
    if cursor > len or text:sub(cursor, cursor) ~= "{" then
      local fallback_end = math.max(cursor - 1, start_pos)
      table.insert(parts, text:sub(start_pos, fallback_end))
      pos = fallback_end + 1
    else
      local depth = 1
      local j = cursor + 1
      while j <= len and depth > 0 do
        local ch = text:sub(j, j)
        if ch == "{" then
          depth = depth + 1
        elseif ch == "}" then
          depth = depth - 1
        end
        j = j + 1
      end
      if depth == 0 then
        local content = text:sub(cursor + 1, j - 2)
        table.insert(parts, "\\scalebox{" .. scale .. "}{\\ensuremath{" .. content .. "}}")
        pos = j
        replacements = replacements + 1
      else
        local fallback_end = math.max(cursor - 1, start_pos)
        table.insert(parts, text:sub(start_pos, fallback_end))
        pos = fallback_end + 1
      end
    end
    ::continue_loop::
  end
  return table.concat(parts), replacements
end

local function indent_line(text, level)
  local prefix = string.rep("\t", level)
  local lines = {}
  for line in text:gmatch("([^\n]+)") do
    table.insert(lines, prefix .. line)
  end
  if text:sub(-1) == "\n" then
    table.insert(lines, prefix)
  end
  return table.concat(lines, "\n")
end

local function clean_choice_chunk(chunk)
  chunk = chunk or ""
  chunk = chunk:gsub("\\chooseone%s*", "")
  chunk = chunk:gsub("\\checkboxchar%s*%b{}", "")
  chunk = chunk:gsub("^%s*%*+", "")
  while true do
    local before = chunk
    chunk = chunk:gsub("^%s*%b[]", "", 1)
    if chunk == before then break end
  end
  return trim(chunk)
end

local function convert_choice_body(body, marker)
  local found = {}
  body:gsub("()\\([A-Za-z]+)(%*?)", function(pos, name, star)
    local lower = name:lower()
    if lower:match("choice$") then
      table.insert(found, {start = pos, name = name, star = star or ""})
    end
    return ""
  end)
  if #found == 0 then
    return nil
  end
  local lines = {}
  for index, info in ipairs(found) do
    local macro_len = #info.name + #info.star + 1
    local start_pos = info.start + macro_len
    local next_start = found[index + 1] and found[index + 1].start or (#body + 1)
    local segment = body:sub(start_pos, next_start - 1)
    segment = clean_choice_chunk(segment)
    if segment ~= "" then
      table.insert(lines, "\\item <m>" .. marker .. "</m> " .. segment)
    else
      table.insert(lines, "\\item <m>" .. marker .. "</m>")
    end
  end
  return table.concat(lines, "\n")
end

local function convert_choice_environment(text, env, marker)
  local pattern = "\n%s*\\begin%s*{%s*" .. env .. "%s*}([%s%S]-)\\end%s*{%s*" .. env .. "%s*}"
  local function replacer(body)
    local converted = convert_choice_body(body, marker)
    if not converted then
      return "\n\\begin{itemize}\n" .. body .. "\n\\end{itemize}"
    end
    return "\n\\begin{itemize}\n" .. converted .. "\n\\end{itemize}"
  end
  local augmented = "\n" .. text
  local replaced = augmented:gsub(pattern, replacer)
  return replaced:sub(2)
end

local function render_paragraph(content, indent)
  content = trim(content)
  if content == "" then
    return nil
  end
  local lines = {}
  table.insert(lines, indent_line("<p>", indent))
  for line in content:gmatch("([^\n]+)") do
    table.insert(lines, indent_line(line, indent + 1))
  end
  table.insert(lines, indent_line("</p>", indent))
  return table.concat(lines, "\n")
end

local function render_statement_parts(parts, indent)
  local lines = {}
  for _, part in ipairs(parts or {}) do
    if part.type == "p" then
      local para = render_paragraph(part.content, indent)
      if para then table.insert(lines, para) end
    elseif part.type == "list" then
      table.insert(lines, render_plain_list(part.tag, part.content, indent))
    end
  end
  return table.concat(lines, "\n")
end

local function dedent_block(text)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, line)
  end
  local min_indent
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local indent = line:match("^(%s*)") or ""
      local width = #indent
      if not min_indent or width < min_indent then
        min_indent = width
      end
    end
  end
  if min_indent and min_indent > 0 then
    for index, line in ipairs(lines) do
      if line:match("%S") then
        lines[index] = line:sub(min_indent + 1)
      end
    end
  end
  return table.concat(lines, "\n")
end

local workspace_lookup = {}

local function read_file_contents(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function build_workspace_lookup(source)
  local lookup = {}
  local stack = {}
  local current_exercise = 0
  local last_task = nil

  local function push(env)
    table.insert(stack, env)
  end

  local function pop(env)
    for index = #stack, 1, -1 do
      local current = stack[index]
      table.remove(stack)
      if current == env then
        break
      end
    end
    if #stack < 2 then
      last_task = nil
    end
  end

  local function record_workspace(line)
    if not last_task then
      return
    end
    local amount = line:match([[\vspace%*?%{%s*([^}]+)%s*%}]])
    if amount then
      amount = amount:gsub("%s+", "")
      local tasks = lookup[last_task.exercise]
      if tasks then
        tasks[last_task.index] = amount
      end
      last_task = nil
    end
  end

  local tracked_envs = {
    enumerate = true,
    itemize = true,
    questions = true,
    parts = true,
  }

  local function scan_command(line, command, handler)
    local pattern = "\\" .. command
    local search_pos = 1
    while true do
      local start_idx, end_idx = line:find(pattern, search_pos, true)
      if not start_idx then
        break
      end
      local next_char = line:sub(end_idx + 1, end_idx + 1)
      if next_char == "" or not next_char:match("%a") then
        handler()
      end
      search_pos = end_idx + 1
    end
  end

  local function handle_list_command()
    local top = stack[#stack]
    if not top then
      return
    end

    if top == "enumerate" or top == "questions" then
      if #stack == 1 then
        current_exercise = current_exercise + 1
        lookup[current_exercise] = {}
        last_task = nil
      elseif #stack == 2 then
        local tasks = lookup[current_exercise]
        if tasks then
          table.insert(tasks, "")
          last_task = {exercise = current_exercise, index = #tasks}
        end
      end
    elseif top == "itemize" or top == "parts" then
      if #stack == 2 and (stack[1] == "enumerate" or stack[1] == "questions") then
        local tasks = lookup[current_exercise]
        if tasks then
          table.insert(tasks, "")
          last_task = {exercise = current_exercise, index = #tasks}
        end
      end
    end
  end

  for line in (source .. "\n"):gmatch("(.-)\n") do
    for env in line:gmatch([[\begin%s*{%s*([%w%*]+)%s*}]]) do
      if tracked_envs[env] then
        push(env)
      end
    end
    for env in line:gmatch([[\end%s*{%s*([%w%*]+)%s*}]]) do
      if tracked_envs[env] then
        pop(env)
      end
    end

    scan_command(line, "item", handle_list_command)
    scan_command(line, "question", handle_list_command)
    scan_command(line, "part", handle_list_command)

    record_workspace(line)
  end

  return lookup
end

local function lookup_workspace(exercise_index, task_index)
  if exercise_index and task_index and workspace_lookup then
    local entries = workspace_lookup[exercise_index]
    if entries then
      return entries[task_index]
    end
  end
  return nil
end

local function strip_outer_list_markup(block, tag)
  block = block:gsub("^<" .. tag .. ">", "", 1)
  block = block:gsub("</" .. tag .. ">$", "", 1)
  return block
end

local function extract_outermost_list(source, tag)
  local open_tag = "<" .. tag .. ">"
  local close_tag = "</" .. tag .. ">"
  local start = source:find(open_tag, 1, true)
  if not start then
    return nil
  end
  local depth = 1
  local pos = start + #open_tag
  while depth > 0 do
    local next_open = source:find(open_tag, pos, true)
    local next_close = source:find(close_tag, pos, true)
    if not next_close then
      return nil
    end
    if next_open and next_open < next_close then
      depth = depth + 1
      pos = next_open + #open_tag
    else
      depth = depth - 1
      pos = next_close + #close_tag
    end
  end
  local before = source:sub(1, start - 1)
  local block = source:sub(start, pos - 1)
  local after = source:sub(pos)
  return before, block, after
end

local function parse_blocks(block_str)
  local blocks = {}
  local rest = block_str or ""

  local function strip_multicolumn_counter(content)
    if not content then
      return content
    end
    local stripped, count = content:gsub("^%s*%d+%s+(<)", "%1", 1)
    if count > 0 then
      return stripped
    end
    stripped, count = content:gsub("^%s*%d+%s+(\\)", "%1", 1)
    if count > 0 then
      return stripped
    end
    local trimmed = trim(content)
    if trimmed:match("^%d+$") then
      return ""
    end
    return content
  end
  while rest do
    rest = rest:gsub("^%s+", "")
    if rest == "" then break end

    -- Strip any leading HTML comments that might wrap other structures
    while true do
      local comment = rest:match("^<!%-%-.-%-%->")
      if not comment then break end
      rest = rest:sub(#comment + 1)
      rest = rest:gsub("^%s+", "")
    end
    if rest == "" then break end

    local handled = false

    if rest:sub(1,3) == "<p>" then
      local para_content, remainder = rest:match("^<p>(.-)</p>(.*)$")
      if para_content then
        local inner_tag = para_content:match("^%s*<(ol)>") or para_content:match("^%s*<(ul)>")
        if inner_tag then
          local before, block, after = extract_outermost_list(para_content, inner_tag)
          if before and trim(before) == "" and trim(after) == "" then
            table.insert(blocks, {type = "list", tag = inner_tag, content = strip_outer_list_markup(block, inner_tag)})
            rest = remainder
            handled = true
          end
        end
      end
    end

    if not handled then
      local direct_tag = rest:match("^<(ol)>") or rest:match("^<(ul)>")
      if direct_tag then
        local before, block, remainder = extract_outermost_list(rest, direct_tag)
        if before and trim(before) ~= "" then
          local cleaned = strip_multicolumn_counter(trim(before))
          table.insert(blocks, {type = "p", content = cleaned})
        end
        if block then
          table.insert(blocks, {type = "list", tag = direct_tag, content = strip_outer_list_markup(block, direct_tag)})
        end
        rest = remainder
        handled = true
      end
    end

    if not handled then
      local amount, remainder = rest:match("^<workspace%s+amount=\"([^\"]+)\"%s*/>(.*)$")
      if amount then
        table.insert(blocks, {type = "workspace", amount = trim(amount)})
        rest = remainder
        handled = true
      end
    end

    if not handled then
      local para_content, remainder = rest:match("^<p>%s*(.-)%s*</p>(.*)$")
      if para_content then
        para_content = strip_multicolumn_counter(para_content)
        table.insert(blocks, {type = "p", content = para_content})
        rest = remainder
      else
        table.insert(blocks, {type = "raw", content = rest})
        break
      end
    end
  end
  return blocks
end

local function parse_list_items(content)
  local items = {}
  if not content then
    return items
  end
  local pos = 1
  while true do
    local start_pos = content:find("<li>", pos)
    if not start_pos then
      break
    end
    local depth = 1
    local scan_pos = start_pos + 4
    while depth > 0 do
      local next_open = content:find("<li>", scan_pos)
      local next_close = content:find("</li>", scan_pos)
      if not next_close then
        scan_pos = #content + 1
        break
      end
      if next_open and next_open < next_close then
        depth = depth + 1
        scan_pos = next_open + 4
      else
        depth = depth - 1
        scan_pos = next_close + 5
      end
    end
    local item_content = content:sub(start_pos + 4, scan_pos - 6)
    table.insert(items, item_content)
    pos = scan_pos
  end
  return items
end

local function extract_points(text)
  local cleaned = trim(text)
  local pts = cleaned:match("^%((%d+)[^%)]*%)")
  if pts then
    cleaned = cleaned:gsub("^%b()", "", 1)
  end
  return pts, trim(cleaned)
end

local function strip_choice_marker(text)
  local without = text:gsub("<m>PTXSINGLE</m>%s*", "")
  without = without:gsub("<m>PTXMULTI</m>%s*", "")
  without = without:gsub("&lt;m&gt;PTXSINGLE&lt;/m&gt;%s*", "")
  without = without:gsub("&lt;m&gt;PTXMULTI&lt;/m&gt;%s*", "")
  without = without:gsub(" ", "")
  return trim(without)
end

local function is_choice_list(content)
  if not content or content == "" then
    return false
  end
  local items = parse_list_items(content)
  if #items == 0 then
    return false
  end
  local has_marker = false
  for _, entry in ipairs(items) do
    local entry_has_marker = entry:find("<m>PTXSINGLE</m>")
      or entry:find("<m>PTXMULTI</m>")
      or entry:find("&lt;m&gt;PTXSINGLE&lt;/m&gt;")
      or entry:find("&lt;m&gt;PTXMULTI&lt;/m&gt;")
    if not entry_has_marker then
      return false
    end
    has_marker = true
  end
  return has_marker
end

local function extract_plain_text(text)
  text = text or ""
  text = text:gsub("<[^>]+>", " ")
  text = text:gsub("&[A-Za-z]+;", " ")
  text = text:gsub("&#x[%x]+;", " ")
  text = text:gsub("&#%d+;", " ")
  text = text:gsub("\\[%a]+", " ")
  text = text:gsub("%s+", " ")
  return trim(text:lower())
end

local function render_plain_list(tag, content, indent)
  local lines = {}
  local open_tag = tag == "ol" and "ol" or "ul"
  table.insert(lines, indent_line("<" .. open_tag .. ">", indent))
  for _, entry in ipairs(parse_list_items(content)) do
    table.insert(lines, indent_line("<li>", indent + 1))
    local blocks = parse_blocks(entry)
    for _, block in ipairs(blocks) do
      if block.type == "p" then
        local para = render_paragraph(block.content, indent + 2)
        if para then table.insert(lines, para) end
      elseif block.type == "list" then
        local nested = render_plain_list(block.tag, block.content, indent + 2)
        table.insert(lines, nested)
      end
    end
    table.insert(lines, indent_line("</li>", indent + 1))
  end
  table.insert(lines, indent_line("</" .. open_tag .. ">", indent))
  return table.concat(lines, "\n")
end

local function determine_forced_mode(list_content, context_text)
  if not list_content then
    return nil
  end
  local has_multi = list_content:find("<m>PTXMULTI</m>")
    or list_content:find("&lt;m&gt;PTXMULTI&lt;/m&gt;")
  local has_single = list_content:find("<m>PTXSINGLE</m>")
    or list_content:find("&lt;m&gt;PTXSINGLE&lt;/m&gt;")
  if not has_multi or has_single then
    return nil
  end
  local plain = extract_plain_text(context_text or "")
  if plain == "" then
    return "no"
  end
  if plain:find("select%s+all") or plain:find("choose%s+all")
    or plain:find("mark%s+all") or plain:find("all%s+that%s+apply")
    or plain:find("all%s+of%s+the%s+following")
    or plain:find("select%s+every") or plain:find("choose%s+each") then
    return "yes"
  end
  return "no"
end

local function render_choices(list_content, indent, forced_mode)
  local has_multi = list_content:find("<m>PTXMULTI</m>") or list_content:find("&lt;m&gt;PTXMULTI&lt;/m&gt;")
  local has_single = list_content:find("<m>PTXSINGLE</m>") or list_content:find("&lt;m&gt;PTXSINGLE&lt;/m&gt;")
  local multiple
  if forced_mode == "yes" or forced_mode == "no" then
    multiple = forced_mode
  else
    multiple = (has_multi and not has_single) and "yes" or "no"
  end
  local lines = {}
  table.insert(lines, indent_line('<choices multiple-correct="' .. multiple .. '">', indent))
  for _, entry in ipairs(parse_list_items(list_content)) do
    local blocks = parse_blocks(entry)
    local paragraphs = {}
    for _, block in ipairs(blocks) do
      if block.type == "p" then
        local cleaned = strip_choice_marker(block.content)
        if cleaned ~= "" then
          table.insert(paragraphs, cleaned)
        end
      end
    end
    table.insert(lines, indent_line("<choice>", indent + 1))
    table.insert(lines, indent_line("<statement>", indent + 2))
    for _, para in ipairs(paragraphs) do
      local rendered = render_paragraph(para, indent + 3)
      if rendered then table.insert(lines, rendered) end
    end
    table.insert(lines, indent_line("</statement>", indent + 2))
    table.insert(lines, indent_line("</choice>", indent + 1))
  end
  table.insert(lines, indent_line("</choices>", indent))
  return table.concat(lines, "\n"), multiple
end

local function normalize_hint(text)
  local inner = text:match("^%s*%((%s*[Hh]int:.-)%)%s*$")
  if inner then
    text = inner
  end
  text = text:gsub("^[Hh]int:?%s*", "", 1)
  return trim(text)
end

local function split_text_and_hints(text)
  local hints = {}
  local source = text or ""
  local parts = {}
  local index = 1
  local length = #source

  while index <= length do
    local start_pos, prefix_end = source:find("%(%s*[Hh]int:?%s*", index)
    if not start_pos then
      table.insert(parts, source:sub(index))
      break
    end

    if start_pos > index then
      table.insert(parts, source:sub(index, start_pos - 1))
    end

    local depth = 1
    local scan = prefix_end + 1
    local closed = false
    while scan <= length do
      local byte = source:byte(scan)
      if byte == 40 then -- '('
        depth = depth + 1
      elseif byte == 41 then -- ')'
        depth = depth - 1
        if depth == 0 then
          local segment = source:sub(start_pos, scan)
          local normalized = normalize_hint(segment)
          if normalized ~= "" then
            table.insert(hints, normalized)
          end
          index = scan + 1
          closed = true
          break
        end
      end
      scan = scan + 1
    end

    if not closed then
      table.insert(parts, source:sub(start_pos))
      break
    end
  end

  local remaining = trim(table.concat(parts, ""))
  if remaining ~= "" and remaining:match("^%(*%s*[Hh]int") then
    local normalized = normalize_hint(remaining)
    if normalized ~= "" then
      table.insert(hints, normalized)
    end
    remaining = ""
  end
  return remaining, hints
end

local function extract_outermost_ol(source)
  local start = source:find("<ol>")
  if not start then
    return nil
  end
  local depth = 0
  local pos = start + 4
  while true do
    local next_open = source:find("<ol>", pos)
    local next_close = source:find("</ol>", pos)
    if not next_close then
      break
    end
    if next_open and next_open < next_close then
      depth = depth + 1
      pos = next_open + 4
    else
      if depth == 0 then
        local finish = next_close + 5
        local before = source:sub(1, start - 1)
        local block = source:sub(start, finish)
        local after = source:sub(finish + 1)
        return before, block, after
      else
        depth = depth - 1
        pos = next_close + 5
      end
    end
  end
  return nil
end

local function collect_statement_text(parts)
  local fragments = {}
  for _, part in ipairs(parts) do
    if part.type == "p" and part.content then
      table.insert(fragments, part.content)
    end
  end
  return trim(table.concat(fragments, " "))
end

local function prepare_task_content(entry, exercise_index, task_index, context_text)
  local entry_kind = "item"
  local entry_content = entry
  if type(entry) == "table" then
    entry_kind = entry.kind or "item"
    entry_content = entry.content or ""
  end
  if entry_kind == "intro_hint" then
    local hints = {}
    if entry_content and entry_content ~= "" then
      table.insert(hints, entry_content)
    end
    return {kind = entry_kind, hints = hints, next_context = context_text}
  end
  local blocks
  if entry_kind == "choices" then
    blocks = {{type = "list", tag = "ul", content = entry_content}}
  else
    blocks = parse_blocks(entry_content)
  end
  local points
  local statement_parts = {}
  local hint_parts = {}
  local choice_list_content = nil
  local workspace
  for index, block in ipairs(blocks) do
    if block.type == "p" then
      local content = block.content
      if index == 1 then
        points, content = extract_points(content)
      end
      if content ~= "" then
        if content:match("^%s*%(*[Hh]int") then
          local hint_text = normalize_hint(content)
          if hint_text ~= "" then
            table.insert(hint_parts, hint_text)
          end
        else
          table.insert(statement_parts, {type = "p", content = content})
        end
      end
    elseif block.type == "list" then
      if is_choice_list(block.content) then
        choice_list_content = block.content
      else
        table.insert(statement_parts, {type = "list", tag = block.tag, content = block.content})
      end
    elseif block.type == "workspace" then
      if not workspace or workspace == "" then
        workspace = block.amount
      end
    end
  end

  local statement_text = collect_statement_text(statement_parts)
  local combined_context = context_text or ""
  if combined_context ~= "" and statement_text ~= "" then
    combined_context = combined_context .. " " .. statement_text
  elseif statement_text ~= "" then
    combined_context = statement_text
  end

  local forced_mode = nil
  if choice_list_content then
    forced_mode = determine_forced_mode(choice_list_content, combined_context)
  end

  if (not workspace or workspace == "") and exercise_index and task_index then
    local from_source = lookup_workspace(exercise_index, task_index)
    if from_source and from_source ~= "" then
      workspace = from_source
    end
  end

  return {
    kind = entry_kind,
    points = points,
    workspace = workspace,
    statement_parts = statement_parts,
    hints = hint_parts,
    choice_list_content = choice_list_content,
    forced_mode = forced_mode,
    next_context = combined_context
  }
end

local function convert_task(entry, indent, exercise_index, task_index, context_text)
  local content = prepare_task_content(entry, exercise_index, task_index, context_text)
  if content.kind == "intro_hint" then
    local lines = {}
    table.insert(lines, indent_line("<task>", indent))
    table.insert(lines, indent_line("<hint>", indent + 1))
    for _, hint_text in ipairs(content.hints or {}) do
      local para = render_paragraph(hint_text, indent + 2)
      if para then table.insert(lines, para) end
    end
    table.insert(lines, indent_line("</hint>", indent + 1))
    table.insert(lines, indent_line("</task>", indent))
    return table.concat(lines, "\n"), context_text
  end

  local attr = ""
  if content.points then
    attr = attr .. ' points="' .. content.points .. '"'
  end
  if content.workspace and content.workspace ~= "" then
    attr = attr .. ' workspace="' .. content.workspace .. '"'
  end
  local lines = {}
  table.insert(lines, indent_line("<task" .. attr .. ">", indent))
  if content.statement_parts and #content.statement_parts > 0 then
    table.insert(lines, indent_line("<statement>", indent + 1))
    local stmt = render_statement_parts(content.statement_parts, indent + 2)
    if stmt ~= "" then table.insert(lines, stmt) end
    table.insert(lines, indent_line("</statement>", indent + 1))
  end
  if content.choice_list_content then
    local choices_markup = render_choices(content.choice_list_content, indent + 2, content.forced_mode)
    table.insert(lines, choices_markup)
  end
  for _, hint_text in ipairs(content.hints or {}) do
    table.insert(lines, indent_line("<hint>", indent + 1))
    local para = render_paragraph(hint_text, indent + 2)
    if para then table.insert(lines, para) end
    table.insert(lines, indent_line("</hint>", indent + 1))
  end
  table.insert(lines, indent_line("</task>", indent))
  return table.concat(lines, "\n"), content.next_context or context_text
end

local function convert_exercise(item, indent, exercise_index)
  local blocks = parse_blocks(item)
  local intro_blocks = {}
  local intro_hint_blocks = {}
  local task_blocks = {}
  for _, block in ipairs(blocks) do
    if block.type == "list" then
      if is_choice_list(block.content) then
        table.insert(task_blocks, {kind = "choices", content = block.content})
      else
        for _, entry in ipairs(parse_list_items(block.content)) do
          table.insert(task_blocks, {kind = "item", content = entry})
        end
      end
    elseif block.type == "p" then
      local cleaned, hints = split_text_and_hints(block.content)
      if cleaned ~= "" then
        table.insert(intro_blocks, cleaned)
      end
      for _, hint_text in ipairs(hints) do
        table.insert(intro_hint_blocks, hint_text)
      end
    end
  end
  local intro_context = trim(table.concat(intro_blocks, " "))
  for _, hint_text in ipairs(intro_hint_blocks) do
    table.insert(task_blocks, {kind = "intro_hint", content = hint_text})
  end
  local intro_points
  if intro_blocks[1] then
    intro_points, intro_blocks[1] = extract_points(intro_blocks[1])
  end

  local has_item_block = false
  for _, entry in ipairs(task_blocks) do
    if entry.kind == "item" then
      has_item_block = true
      break
    end
  end
  local treat_as_parts = has_item_block

  if treat_as_parts then
    local attr = ""
    if intro_points then
      attr = attr .. ' points="' .. intro_points .. '"'
    end
    local lines = {}
    table.insert(lines, indent_line("<exercise" .. attr .. ">", indent))
    if #intro_blocks > 0 then
      table.insert(lines, indent_line("<introduction>", indent + 1))
      for _, content in ipairs(intro_blocks) do
        local para = render_paragraph(content, indent + 2)
        if para then table.insert(lines, para) end
      end
      table.insert(lines, indent_line("</introduction>", indent + 1))
    end
    local context_text = intro_context
    for idx, entry in ipairs(task_blocks) do
      local task_markup, updated_context = convert_task(entry, indent + 1, exercise_index, idx, context_text)
      table.insert(lines, task_markup)
      context_text = updated_context or context_text
    end
    table.insert(lines, indent_line("</exercise>", indent))
    return table.concat(lines, "\n")
  end

  local statement_parts = {}
  for _, content in ipairs(intro_blocks) do
    table.insert(statement_parts, {type = "p", content = content})
  end
  local hints = {}
  local workspace_amount = nil
  local choice_data = nil
  local derived_points = intro_points
  local context_text = intro_context
  for idx, entry in ipairs(task_blocks) do
    local prepared = prepare_task_content(entry, exercise_index, idx, context_text)
    context_text = prepared.next_context or context_text
    if entry.kind == "intro_hint" then
      for _, hint_text in ipairs(prepared.hints or {}) do
        table.insert(hints, hint_text)
      end
    else
      for _, part in ipairs(prepared.statement_parts or {}) do
        table.insert(statement_parts, part)
      end
      if prepared.choice_list_content then
        choice_data = {content = prepared.choice_list_content, forced_mode = prepared.forced_mode}
      end
      for _, hint_text in ipairs(prepared.hints or {}) do
        table.insert(hints, hint_text)
      end
      if (not derived_points or derived_points == "") and prepared.points and prepared.points ~= "" then
        derived_points = prepared.points
      end
      if prepared.workspace and prepared.workspace ~= "" then
        workspace_amount = workspace_amount or prepared.workspace
      end
    end
  end

  local attr = ""
  if derived_points and derived_points ~= "" then
    attr = attr .. ' points="' .. derived_points .. '"'
  end
  local lines = {}
  table.insert(lines, indent_line("<exercise" .. attr .. ">", indent))
  if #statement_parts > 0 then
    table.insert(lines, indent_line("<statement>", indent + 1))
    local stmt = render_statement_parts(statement_parts, indent + 2)
    if stmt ~= "" then table.insert(lines, stmt) end
    table.insert(lines, indent_line("</statement>", indent + 1))
  end
  if choice_data then
    local choices_markup = render_choices(choice_data.content, indent + 2, choice_data.forced_mode)
    table.insert(lines, choices_markup)
  end
  if workspace_amount and workspace_amount ~= "" then
    table.insert(lines, indent_line('<workspace amount="' .. workspace_amount .. '"/>', indent + 1))
  end
  for _, hint_text in ipairs(hints) do
    table.insert(lines, indent_line("<hint>", indent + 1))
    local para = render_paragraph(hint_text, indent + 2)
    if para then table.insert(lines, para) end
    table.insert(lines, indent_line("</hint>", indent + 1))
  end
  table.insert(lines, indent_line("</exercise>", indent))
  return table.concat(lines, "\n")
end

-- This function is called once for the whole document. Parameters:
-- body is a string, metadata is a table, variables is a table.
-- This gives you a fragment.  You could use the metadata table to
-- fill variables in a custom lua template.  Or, pass `--template=...`
-- to pandoc, and pandoc will add do the template processing as
-- usual.
function Doc(body, metadata, variables)

  -- close any open sections:
  while 1 <= #sectionBuffer do
    body = body .. "\n" .. string.rep("\t",#sectionBuffer) .. "</".. sectionBuffer[1]..">\n"
    table.remove(sectionBuffer,1)
  end
  local doc_id
  if metadata and metadata.identifier and metadata.identifier ~= "" then
    doc_id = sanitize_identifier(trim(metadata.identifier))
  end
  if (not doc_id or doc_id == "") and PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
    local input_path = PANDOC_STATE.input_files[1]
    if input_path and input_path ~= "" then
      local sanitized = sanitize_identifier(input_path)
      if sanitized ~= "" then
        doc_id = sanitized
      end
    end
  end
  if not doc_id or doc_id == "" then
    doc_id = "document"
  end

  workspace_lookup = {}
  local source
  if PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
    source = read_file_contents(PANDOC_STATE.input_files[1])
    if source then
      local converted_source, scale_replacements = convert_scale_macros(source)
      if scale_replacements > 0 then
        source = converted_source
      end
      workspace_lookup = build_workspace_lookup(source)
    end
  end

  local skip_normalize = os.getenv("PTX_SKIP_Q_NORMALIZE") == "1"
  if not skip_normalize and source and source:find([[\begin%s*{%s*questions%s*}]]) and script_path then
    local normalized = source
    normalized = normalized:gsub([[\begin%s*{%s*questions%s*}]], "\\begin{enumerate}")
    normalized = normalized:gsub([[\end%s*{%s*questions%s*}]], "\\end{enumerate}")
    normalized = normalized:gsub([[\begin%s*{%s*parts%s*}]], "\\begin{itemize}")
    normalized = normalized:gsub([[\end%s*{%s*parts%s*}]], "\\end{itemize}")
    normalized = normalized:gsub([[\checkboxchar%s*%b{}]], "")
    normalized = convert_choice_environment(normalized, "checkboxes", "PTXMULTI")
    normalized = convert_choice_environment(normalized, "choices", "PTXSINGLE")
    normalized = normalized:gsub("\\question%[", "\\item[")
    normalized = normalized:gsub("\\question(%W)", function(follow)
      return "\\item" .. follow
    end)
    normalized = normalized:gsub("\\question$", "\\item")
    normalized = normalized:gsub("\\part%[", "\\item[")
    normalized = normalized:gsub("\\part(%W)", function(follow)
      return "\\item" .. follow
    end)
    normalized = normalized:gsub("\\part$", "\\item")

    local tmp_path = os.tmpname()
    local tmp = io.open(tmp_path, "w")
    if tmp then
      tmp:write(normalized)
      tmp:close()
      local command = "PTX_SKIP_Q_NORMALIZE=1 pandoc -f latex"
      if doc_id and doc_id ~= "" then
        command = command .. " " .. shell_quote("--metadata=identifier:" .. doc_id)
      end
      command = command .. " -t " .. shell_quote(script_path) .. " " .. shell_quote(tmp_path)
      local ok_run, normalized_output = pcall(pipe, "sh", {"-c", command}, "")
      os.remove(tmp_path)
      if ok_run and normalized_output and normalized_output ~= "" then
        return normalized_output
      end
    else
      os.remove(tmp_path)
    end
  end

  body = trim(body)
  local before, ol_block, after = extract_outermost_ol(body)
  local exercises_str = ""
  if ol_block then
    local inner = ol_block:match("^%s*<ol>%s*(.*)%s*</ol>%s*$")
    if inner then
      local exercise_parts = {}
      local exercise_index = 0
      for _, item in ipairs(parse_list_items(inner)) do
        exercise_index = exercise_index + 1
        table.insert(exercise_parts, convert_exercise(item, 1, exercise_index))
      end
      exercises_str = table.concat(exercise_parts, "\n")
    end
  end
  local assembled = ""
  if before and trim(before) ~= "" then
    local intro_content = dedent_block(trim(before))
    assembled = indent_line("<introduction>", 1) .. "\n" .. indent_line(intro_content, 2) .. "\n" .. indent_line("</introduction>", 1) .. "\n"
  end
  assembled = assembled .. exercises_str
  if after and trim(after) ~= "" then
    assembled = assembled .. after
  end
  body = assembled

  doc_id = sanitize_identifier(doc_id)
  local title = doc_id
  local header = '<?xml version="1.0" encoding="utf-8"?>\n<worksheet xml:id="' .. doc_id .. '" xmlns:xi="http://www.w3.org/2001/XInclude">'
  local title_line = indent_line("<title>" .. title .. "</title>", 1)
  local footer = "</worksheet>"
  return header .. "\n" .. title_line .. "\n" .. body .. "\n" .. footer
end


-- Chose the image format based on the value of the
-- `image_format` meta value.
-- local image_format = meta.image_format
--   and stringify(meta.image_format)
--   or "png"
-- local image_mime_type = ({
--     jpeg = "image/jpeg",
--     jpg = "image/jpeg",
--     gif = "image/gif",
--     png = "image/png",
--     svg = "image/svg+xml",
--   })[image_format]
--   or error("unsupported image format `" .. img_format .. "`")
  
-- Character escaping
-- (might want to remove the quotes, double check pretext)
local function escape(s, in_attribute)
  return s:gsub("[<>&\"']",
    function(x)
      if x == '<' then
        return '&lt;'
      elseif x == '>' then
        return '&gt;'
      elseif x == '&' then
        return '&amp;'
      -- elseif x == '"' then
      --   return '&quot;'
      -- elseif x == "'" then
      --   return '&#39;'
      else
        return x
      end
    end)
end

-- Helper function to convert an attributes table into
-- a string that can be put into HTML tags.
local function attributes(attr)
  local attr_table = {}
  for x,y in pairs(attr) do
    if y and y ~= "" then
      if x == "id" then
        table.insert(attr_table, ' xml:id="' .. escape(y,true)..'"')
      else
        table.insert(attr_table, ' '..x .. '="' .. escape(y,true) .. '"')
      end
    end
  end
  return table.concat(attr_table)
end

-- Blocksep is used to separate block elements.
function Blocksep()
  return "\n\n"
end

-- The functions that follow render corresponding pandoc elements.
-- s is always a string, attr is always a table of attributes, and
-- items is always an array of strings (the items in a list).
-- Comments indicate the types of other variables.

function Str(s)
  return escape(s)
end

function Space()
  return " "
end

function SoftBreak()
  return " "
end

--No PreTeXt equivalent to linebreak.  Comment inserted for manual post-processing.
function LineBreak()
 return "<!-- linebreak -->"
end

function Emph(s)
  return "<em>" .. s .. "</em>"
end

function Underline(s)
  return '<emphasis role="underline">' .. s .. '</emphasis>'
end

-- No <bold> tag in PreTeXt, but <term> gives bold look.  Assume bold in source document denotes a term, otherwise author could search for <term> and fix case-by-case.
function Strong(s)
  return "<term>" .. s .. "</term>"
end

function Subscript(s)
  return "<sub>" .. s .. "</sub>"
end

function Superscript(s)
  return "<sup>" .. s .. "</sup>"
end

-- No <smallcaps> in PreTeXt.  <alert> can be searched for and changed case-by-case.
function SmallCaps(s)
  return '<alert>' .. s .. '</alert>'
end

-- could also be "gone"
function Strikeout(s)
  return '<delete>' .. s .. '</delete>'
end

function Link(s, src, tit, attr)
  if string.sub(src, 1, 1) == "#" then
    return '<xref ref="'..escape(string.sub(src, 2))..'" />'
  else
    return '<url href="' .. escape(src,true) .. '">' .. s .. '</url>'
  end
end

-- Should this be enclosed in something like a stand-alone side-by-side?
function Image(s, src, tit, attr)
  return "<image source='" .. escape(src,true) .. "'/>"
end

function Code(s, attr)
  return "<c" .. attributes(attr) .. ">" .. escape(s) .. "</c>"
end

function InlineMath(s)
  local currency_amount = s:match("^\\$([%d,%.%,%s]*%d)$")
  if currency_amount then
    return "$" .. escape(currency_amount)
  end
  return "<m>" .. escape(s) .. "</m>"
end

function DisplayMath(s)
  return "<me>" .. escape(s) .. "</me>"
end

function SingleQuoted(s)
  return "<sq>" .. s .. "</sq>"
end

function DoubleQuoted(s)
  return "<q>" .. s .. "</q>"
end

function Note(s)
  return "<fn>" .. s .. "</fn>"
end

function Span(s, attr)
 -- return "<span" .. attributes(attr) .. ">" .. s .. "</span>"
 return s
end

-- RowInline is a way to pass certain html or latex directly to the output if there is no equivalent in the AST.  Seems to only be for \cite, \ref. For now, we just leave it blank, so these elements are just dropped.
function RawInline(format, str)
  -- if format == "html" then
  --   return "<raw-html>"..str.."</raw-html>"
  -- else
  --   return "<raw "..format..">"..str.."</raw>"
  -- end
  return ''
end

-- FIXME: this might still be wrong.  Specifically, not sure what happens when multiple ids are present.
function Cite(s, cs)
  local ids = {}
  for _,cit in ipairs(cs) do
    table.insert(ids, cit.citationId)
  end
  return "<xref ref=\"" .. table.concat(ids, ",") ..
    "\">" .. s .. "</xref>"
end

function Plain(s)
  return s
end

function Para(s)
  -- here and below: tabs and tabsp(lus) are strings that add enough tab characters to make the output indented nicely.  Since "indents" changes each time these functions are called, these local variables need to be redefined each time.
  local tabs = string.rep("\t", indents)
  local tabsp = string.rep("\t", indents+1)
  return tabs.."<p>\n" .. tabsp .. s .. "\n".. tabs.."</p>"
end


function BlockQuote(s)
  local tabs = string.rep("\t", indents)
  local tabsp = string.rep("\t", indents+1)
  return tabs.."<blockquote>\n" ..tabsp.. s .. "\n"..tabs.."</blockquote>"
end

-- No <hrule> in PreTeXt.  Leave comment to be searched for.
function HorizontalRule()
--  return "<hr/>"
  return "<!-- Horizontal Rule Not Implimented -->"
end

-- Not sure what this does, so leaving as divs for now, until I see it show up.
function LineBlock(ls)
  return '<div style="white-space: pre-line;">' .. table.concat(ls, '\n') ..
         '</div>'
end

function CodeBlock(s, attr)
  local tabs = string.rep("\t", indents)
  -- -- If code block has class 'dot', pipe the contents through dot
  -- -- and base64, and include the base64-encoded png as a data: URL.
  -- if attr.class and string.match(' ' .. attr.class .. ' ',' dot ') then
  --   local img = pipe("base64", {}, pipe("dot", {"-T" .. image_format}, s))
  --   return '<img src="data:' .. image_mime_type .. ';base64,' .. img .. '"/>'
  -- -- otherwise treat as code (one could pipe through a highlighter)
  -- else
    return tabs.."<pre>" .. escape(s) ..
           "</pre>"
  -- end
end

function BulletList(items)
  local tabs = string.rep("\t", indents)
  local buffer = {}
  for _, item in ipairs(items) do
    local content = indent_line(trim(item), indents + 2)
    table.insert(buffer, indent_line("<li>", indents + 1))
    if content ~= "" then
      table.insert(buffer, content)
    end
    table.insert(buffer, indent_line("</li>", indents + 1))
  end
  return tabs .. "<ul>\n" .. table.concat(buffer, "\n") .. "\n" .. tabs .. "</ul>"
end

function OrderedList(items)
  local tabs = string.rep("\t", indents)
  local buffer = {}
  for _, item in ipairs(items) do
    local content = indent_line(trim(item), indents + 2)
    table.insert(buffer, indent_line("<li>", indents + 1))
    if content ~= "" then
      table.insert(buffer, content)
    end
    table.insert(buffer, indent_line("</li>", indents + 1))
  end
  return tabs .. "<ol>\n" .. table.concat(buffer, "\n") .. "\n" .. tabs .. "</ol>"
end

function DefinitionList(items)
  local tabs = string.rep("\t", indents)
  local tabsp = string.rep("\t", indents+1)
  local tabspp = string.rep("\t", indents+2)
  local buffer = {}
  for _,item in pairs(items) do
    local k, v = next(item)
    table.insert(buffer, tabsp.."<dt>" .. k .. "</dt>\n"..tabspp.."<dd>" ..
                   table.concat(v, "</dd>\n<dd>") .. "</dd>")
  end
  return tabs.."<dl>\n" .. table.concat(buffer, "\n") .. "\n"..tabs.."</dl>"
end

-- PreTeXt does not have anything like this, but leaving it in to avoid errors.  Author can search and address case-by-case.
-- Convert pandoc alignment to something HTML can use.
-- align is AlignLeft, AlignRight, AlignCenter, or AlignDefault.
function html_align(align)
  if align == 'AlignLeft' then
    return 'left'
  elseif align == 'AlignRight' then
    return 'right'
  elseif align == 'AlignCenter' then
    return 'center'
  else
    return 'left'
  end
end

function CaptionedImage(src, tit, caption, attr)
  local tabs = string.rep("\t", indents)
  local tabsp = string.rep("\t", indents+1)
   return tabs..'<figure>\n\t<image source="' .. escape(src,true) ..
      '"/>\n' ..
      tabsp..'<caption>' .. caption .. '</caption>\n</figure>'
end

-- Caption is a string, aligns is an array of strings,
-- widths is an array of floats, headers is an array of
-- strings, rows is an array of arrays of strings.
function Table(caption, aligns, widths, headers, rows)
  local tabs = string.rep("\t", indents)
  local tabsp = string.rep("\t", indents+1)
  local tabspp = string.rep("\t", indents+2)
  local buffer = {}
  local function add(s)
    table.insert(buffer, s)
  end
  add(tabs.."<table>")
  -- if caption ~= "" then -- tabules need captions always
    add(tabsp.."<title>" .. caption .. "</title>")
  -- end
  if widths and widths[1] ~= 0 then
    for _, w in pairs(widths) do
      add('<col width="' .. string.format("%.0f%%", w * 100) .. '" />')
    end
  end
  add(tabsp..'<tabular>')
  local header_row = {}
  local empty_header = true
  for i, h in pairs(headers) do
    local align = html_align(aligns[i])
    table.insert(header_row, tabspp..'<cell halign="' .. align .. '">' .. h .. '</cell>')
    empty_header = empty_header and h == ""
  end
  if empty_header then
    head = ""
  else
    add(tabsp..'<row header="yes">')
    for _,h in pairs(header_row) do
      add(h)
    end
    add(tabsp..'</row>')
  end
  local class = "even"
  for _, row in pairs(rows) do
    class = (class == "even" and "odd") or "even"
    add(tabsp..'<row class="' .. class .. '">')
    for i,c in pairs(row) do
      add(tabspp..'<cell halign="' .. html_align(aligns[i]) .. '">' .. c .. '</cell>')
    end
    add(tabsp..'</row>')
  end
  add(tabsp..'</tabular>\n'..tabs..'</table>')
  return table.concat(buffer,'\n')
end

function RawBlock(format, str)
  if format == "latex" then
    local workspace = str:match("\\vspace%*?%{%s*([^}]+)%s*%}")
    if workspace then
      workspace = workspace:gsub("%s+", "")
      return '<workspace amount="' .. escape(workspace, true) .. '"/>'
    end
  end
  return "<cd>\n" .. str .. "\n</cd>"
end

-- We use "sectionBuffer" to keep track of open division names, and close them when headers of not-higher levels are reached.  
-- Note this puts the close division tags after <divs>, if those were implimented.
-- lev is an integer, the header level.
function Header(lev, s, attr)
  -- buffer holds closing tags.
  local buffer = ""
  -- if the current level is less than the current number of nestings, close it up.
  while lev <= #sectionBuffer do
    buffer = buffer .. string.rep("\t",#sectionBuffer) .. "</".. sectionBuffer[1]..">\n"
    table.remove(sectionBuffer,1)
  end
  -- add the current division to the stack.
  table.insert(sectionBuffer,1,sectionNames[lev])
  -- Find numbers of tabs:
  indents = #sectionBuffer + 1
  local tabs = string.rep("\t", indents-1)
  local tabsp = string.rep("\t", indents)
  -- return closing division tags, starting division tag and title:
  return buffer .. "\n" .. tabs .. "<"..sectionNames[lev]..attributes(attr)..">\n" .. tabsp.."<title>"..s.."</title>"
end

-- Divs only seem to show up with specific markdown (or maybe converting from HTML).  The issue is that opening div's show up before new headers, so the close division tags and open div tags are in the wrong order.  Eventually, this could be switched in post processing (Doc function).
function Div(s, attr)
  -- return "<div" .. attributes(attr) .. ">\n" .. s .. "</div>"
  return '<!-- div attr='..attributes(attr).. '-->\n'..s..'<!--</div attr='.. attributes(attr)..'>-->'
end


-- The following code will produce runtime warnings when you haven't defined
-- all of the functions you need for the custom writer, so it's useful
-- to include when you're working on a writer.
local meta = {}
meta.__index =
  function(_, key)
    io.stderr:write(string.format("WARNING: Undefined function '%s'\n",key))
    return function() return "" end
  end
setmetatable(_G, meta)

