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

-- The following breaks older pandoc installs, and it doesn't seem to be necessary for what I want to do.
-- local pipe = pandoc.pipe
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

local function parse_blocks(block_str)
  local blocks = {}
  local rest = block_str or ""
  while rest do
    rest = rest:gsub("^%s+", "")
    if rest == "" then break end
    local tag, list_content, remainder = rest:match("^<p><(ol)>(.-)</ol></p>(.*)$")
    if not tag then
      tag, list_content, remainder = rest:match("^<(ol)>(.-)</ol>(.*)$")
    end
    if tag then
      table.insert(blocks, {type = "list", tag = tag, content = list_content})
      rest = remainder
    else
      tag, list_content, remainder = rest:match("^<p><(ul)>(.-)</ul></p>(.*)$")
      if not tag then
        tag, list_content, remainder = rest:match("^<(ul)>(.-)</ul>(.*)$")
      end
      if tag then
        table.insert(blocks, {type = "list", tag = tag, content = list_content})
        rest = remainder
      else
        local para_content
        para_content, remainder = rest:match("^<p>%s*(.-)%s*</p>(.*)$")
        if para_content then
          table.insert(blocks, {type = "p", content = para_content})
          rest = remainder
        else
          table.insert(blocks, {type = "raw", content = rest})
          break
        end
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
  local without = text:gsub("<m>\\Circle</m>%s*", "")
  without = without:gsub("<m>\\Square</m>%s*", "")
  without = without:gsub(" ", "")
  return trim(without)
end

local function is_choice_list(content)
  if not content then return false end
  return content:find("<m>\\Circle</m>") or content:find("<m>\\Square</m>")
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

local function render_choices(list_content, indent)
  local multiple = list_content:find("<m>\\Square</m>") and "yes" or "no"
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

local function convert_task(entry, indent)
  local blocks = parse_blocks(entry)
  local points
  local statement_parts = {}
  local hint_parts = {}
  local choices_markup = nil
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
        choices_markup = render_choices(block.content, indent + 2)
      else
        table.insert(statement_parts, {type = "list", tag = block.tag, content = block.content})
      end
    end
  end

  local attr = ""
  if points then
    attr = attr .. ' points="' .. points .. '"'
  end
  local lines = {}
  table.insert(lines, indent_line("<task" .. attr .. ">", indent))
  if #statement_parts > 0 then
    table.insert(lines, indent_line("<statement>", indent + 1))
    for _, part in ipairs(statement_parts) do
      if part.type == "p" then
        local para = render_paragraph(part.content, indent + 2)
        if para then table.insert(lines, para) end
      elseif part.type == "list" then
        table.insert(lines, render_plain_list(part.tag, part.content, indent + 2))
      end
    end
    table.insert(lines, indent_line("</statement>", indent + 1))
  end
  if choices_markup then
    table.insert(lines, choices_markup)
  end
  for _, hint_text in ipairs(hint_parts) do
    table.insert(lines, indent_line("<hint>", indent + 1))
    local para = render_paragraph(hint_text, indent + 2)
    if para then table.insert(lines, para) end
    table.insert(lines, indent_line("</hint>", indent + 1))
  end
  table.insert(lines, indent_line("</task>", indent))
  return table.concat(lines, "\n")
end

local function convert_exercise(item, indent)
  local blocks = parse_blocks(item)
  local intro_blocks = {}
  local task_blocks = {}
  for _, block in ipairs(blocks) do
    if block.type == "list" then
      for _, entry in ipairs(parse_list_items(block.content)) do
        table.insert(task_blocks, entry)
      end
    elseif block.type == "p" then
      table.insert(intro_blocks, block.content)
    end
  end
  local intro_points
  if intro_blocks[1] then
    intro_points, intro_blocks[1] = extract_points(intro_blocks[1])
  end
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
  for _, entry in ipairs(task_blocks) do
    table.insert(lines, convert_task(entry, indent + 1))
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
    doc_id = trim(metadata.identifier)
  end
  if (not doc_id or doc_id == "") and PANDOC_STATE and PANDOC_STATE.input_files and #PANDOC_STATE.input_files > 0 then
    local name = PANDOC_STATE.input_files[1]
    name = name:gsub(".*[/\\]", "")
    name = name:gsub("%.[^.]+$", "")
    if name ~= "" then
      doc_id = name
    end
  end
  if not doc_id or doc_id == "" then
    doc_id = "document"
  end

  body = trim(body)
  local before, ol_block, after = extract_outermost_ol(body)
  local exercises_str = ""
  if ol_block then
    local inner = ol_block:match("^%s*<ol>%s*(.*)%s*</ol>%s*$")
    if inner then
      local exercise_parts = {}
      for _, item in ipairs(parse_list_items(inner)) do
        table.insert(exercise_parts, convert_exercise(item, 1))
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

