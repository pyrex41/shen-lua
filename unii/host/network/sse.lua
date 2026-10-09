-- Incremental Server-Sent Events parser.
--
-- Feed arbitrary byte chunks. Complete events are returned as a list.
-- A blank line dispatches an event only when at least one data field was
-- seen. Comment lines (leading ':') are ignored, which covers OpenAI
-- keep-alive comments. data fields are joined with LF per the SSE spec.
-- The trailing '[DONE]' sentinel is flagged as event.done.

local DEFAULT_MAX = 1024 * 1024

local Parser = {}
Parser.__index = Parser

local function new(max_buf)
  return setmetatable({
    buf = "",
    data = nil,
    event = nil,
    id = nil,
    max_buf = max_buf or DEFAULT_MAX,
  }, Parser)
end

local function take_line(self)
  local nl = self.buf:find("\n", 1, true)
  if not nl then return nil end
  local line = self.buf:sub(1, nl - 1)
  self.buf = self.buf:sub(nl + 1)
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end
  return line
end

local function dispatch(self)
  if not self.data then
    self.event = nil
    self.id = nil
    return nil
  end
  local data = table.concat(self.data, "\n")
  local ev = {
    event = self.event,
    data = data,
    id = self.id,
    done = data == "[DONE]",
  }
  self.data = nil
  self.event = nil
  self.id = nil
  return ev
end

function Parser:push(chunk)
  if type(chunk) ~= "string" then
    return nil, "sse chunk must be a string"
  end
  if #self.buf + #chunk > self.max_buf then
    return nil, "sse buffer limit"
  end
  self.buf = self.buf .. chunk
  local events = {}
  while true do
    local line = take_line(self)
    if line == nil then break end
    if line == "" then
      local ev = dispatch(self)
      if ev then events[#events + 1] = ev end
    elseif line:sub(1, 1) ~= ":" then
      local field, value
      local colon = line:find(":", 1, true)
      if not colon then
        field = line
        value = ""
      else
        field = line:sub(1, colon - 1)
        value = line:sub(colon + 1)
        if value:sub(1, 1) == " " then value = value:sub(2) end
      end
      if field == "data" then
        self.data = self.data or {}
        self.data[#self.data + 1] = value
      elseif field == "event" then
        self.event = value
      elseif field == "id" then
        if value ~= "" then self.id = value end
      end
    end
  end
  return events
end

return {
  new = new,
  DEFAULT_MAX = DEFAULT_MAX,
}
