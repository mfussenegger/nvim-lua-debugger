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
      debug.sethook()
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


local function mk_event(event)
  local result = {
    type = 'event';
    event = event;
    seq = session.seq or 1;
  }
  session.seq = result.seq + 1
  return result
end


local function mk_response(request, response)
  local result = {
    type = 'response';
    seq = session.req or 1;
    request_seq = request.seq;
    command = request.command;
    success = true;
  }
  session.seq = result.seq + 1
  return vim.tbl_extend('error', result, response)
end


local function debugger_loop()
  while true do
    local ev = coroutine.yield()
    print(env)
  end
end


function handlers.initialize(client, request)
  local payload = request.arguments
  session = {
    seq = request.seq;
    client = client;
    linesStartAt1 = payload.linesStartAt1 or 1;
    columnsStartAt1 = payload.columnsStartAt1 or 1;
    supportsRunInTerminalRequest = payload.supportsRunInTerminalRequest or false;
    breakpoints = {};
    coro_debugger = coroutine.create(debugger_loop)
  }
  assert(
    not payload.pathFormat or payload.pathFormat == 'path',
    "Only 'path' pathFormat is supported, got: " .. payload.pathFormat
  )
  client:write(msg_with_content_length(json_encode(mk_response(
    request, {
      body = {
      };
    }
  ))))
  client:write(msg_with_content_length(json_encode(mk_event('initialized'))))
end


function handlers.setBreakpoints(client, request)
  local payload = request.arguments
  local result_bps = {}
  local result = {
    body = {
      breakpoints = result_bps;
    };
  };

  local bps = {}
  session.breakpoints = bps

  for _, bp in ipairs(payload.breakpoints or {}) do
    local line_bps = bps[bp.line]
    if not line_bps then
      line_bps = {}
      bps[bp.line] = line_bps
    end
    local full_path = vim.fn.fnamemodify(payload.source.path, ':p')
    line_bps[full_path] = true
    table.insert(result_bps, {
      verified = true;
    })
  end
  print('set breakpoints', vim.inspect(session.breakpoints))
  client:write(msg_with_content_length(json_encode(mk_response(
    request, result
  ))))
end


function handlers.attach()
  debug.sethook(function(event, line)
    if event == "line" then
      local bp = session.breakpoints[line]
      if not bp then
        return
      end
      local info = debug.getinfo(2, "S")
      local source_path = info.source
      if source_path:sub(1, 1) == '@' then
        local path = source_path:sub(2)
        if bp[path] then
          print(vim.inspect(info))

          local event_msg = mk_event('stopped')
          event_msg.body = {
            reason = 'breakpoint';
            threadId = 1;
          }
          session.client:write(msg_with_content_length(json_encode(event_msg)))
          vim.schedule_wrap(coroutine.yield)
          print('resumed')
        end
      end
      -- if info.short_src ~= "vim.lua" then
      --     coroutine.resume(session.coro_debugger, 'breakpoint')
      -- end
    end
  end, "clr")
end


function handlers.threads(client, request)
  client:write(msg_with_content_length(json_encode(mk_response(
    request, {
      body = {
        threads = {
          {
            id = 1;
            name = 'main';
          },
        };
      };
    }
  ))))
end


function handlers.stackTrace(client, request)
  client:write(msg_with_content_length(json_encode(mk_response(
    request, {
      body = {
        stackFrames = {}
      };
    }
  ))))
end


local function handle_request(client, request_str)
  local request = json_decode(request_str)
  --print(vim.inspect(request))
  assert(request.type == 'request', 'request must have type `request` not ' .. vim.inspect(request))
  local handler = handlers[request.command]
  assert(handler, 'Missing handler for ' .. request.command)
  handler(client, request)
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

function M.foo()
  print('a')
  print('b')
end

return M
