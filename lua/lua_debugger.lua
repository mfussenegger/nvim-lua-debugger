local uv = vim.loop
local M = {}
local handlers = {}
local session = {}

local json_decode = vim.fn.json_decode
local json_encode = vim.fn.json_encode



local function msg_with_content_length(msg)
  return table.concat {
    'Content-Length: ';
    tostring(#msg);
    '\r\n\r\n';
    msg
  }
end


local function parse_headers(header)
  if type(header) ~= 'string' then
    return nil
  end
  local headers = {}
  for line in vim.gsplit(header, '\r\n', true) do
    if line == '' then
      break
    end
    local key, value = line:match('^%s*(%S+)%s*:%s*(.+)%s*$')
    if key then
      key = key:lower():gsub('%-', '_')
      headers[key] = value
    else
      error(string.format("Invalid header line %q", line))
    end
  end
  headers.content_length = tonumber(headers.content_length)
    or error(string.format("Content-Length not found in headers. %q", header))
  return headers
end


local header_start_pattern = ("content"):gsub("%w", function(c) return "["..c..c:upper().."]" end)
local function parse_chunk_loop()
  local buffer = ''
  while true do
    local start, finish = buffer:find('\r\n\r\n', 1, true)
    if start then
      local buffer_start = buffer:find(header_start_pattern)
      local headers = parse_headers(buffer:sub(buffer_start, start - 1))
      buffer = buffer:sub(finish + 1)
      local content_length = headers.content_length
      while #buffer < content_length do
        buffer = buffer .. (coroutine.yield()
          or error("Expected more data for the body. The server may have died."))
      end
      local body = buffer:sub(1, content_length)
      buffer = buffer:sub(content_length + 1)
      buffer = buffer .. (coroutine.yield(headers, body)
        or error("Expected more data for the body. The server may have died."))
    else
      buffer = buffer .. (coroutine.yield()
        or error("Expected more data for the header. The server may have died."))
    end
  end
end


local function create_read_loop(server, client, handle_request)
  local parse_chunk = coroutine.wrap(parse_chunk_loop)
  parse_chunk()
  return function (err, chunk)
    assert(not err, err)
    if not chunk then
      -- EOF
      client:close()
      server:close()
      return
    end
    while true do
      local headers, body = parse_chunk(chunk)
      if headers then
        vim.schedule(function()
          handle_request(client, body)
        end)
        chunk = ''
      else
        break
      end
    end
  end
end


function handlers.initialize(payload)
  session = {}
  session.linesStartAt1 = payload.linesStartAt1 or 1
  session.columnsStartAt1 = payload.columnsStartAt1 or 1
  session.supportsRunInTerminalRequest = payload.supportsRunInTerminalRequest or false
  assert(
    not payload.pathFormat or payload.pathFormat == 'path',
    "Only 'path' pathFormat is supported, got: " .. payload.pathFormat
  )
  return {
    body = {
    };
  };
end


function handlers.attach()
  return {}
end


local function handle_request(client, request_str)
  local request = json_decode(request_str)
  print(vim.inspect(request))
  assert(request.type == 'request', 'request must have type `request` not ' .. vim.inspect(request))
  local handler = handlers[request.command]
  assert(handler, 'Missing handler for ' .. request.command)
  local response = handler( request.arguments)
  local response_skeleton = {
    type = 'response';
    request_seq = request.seq;
    seq = request.seq + 1;
    success = true;
    command = request.command;
  }
  if response then
    local final_resp = vim.tbl_extend('error', response_skeleton, response)
    print(vim.inspect(final_resp))
    local msg = msg_with_content_length(json_encode(final_resp))
    client:write(msg)
  end
end


local function on_connect(server, client)
  print("Client connected", client, vim.inspect(client:getsockname()), vim.inspect(client:getpeername()))
  client:read_start(create_read_loop(server, client, handle_request))
end


function M.launch()
  print('Launching Debug Adapter')
  local server = uv.new_tcp()
  local host = '127.0.0.1'
  server:bind(host, 0)
  server:listen(128, function(err)
    assert(not err, err)
    local sock = uv.new_tcp()
    server:accept(sock)
    on_connect(server, sock)
  end)
  return {
    host = host;
    port = server:getsockname().port
  }
end

return M
