-- Copyright (C) Jinhua Luo

local ffi = require("ffi")
local anl = ffi.load("anl")
local C = require("ljio.cdef")
local signal = require("ljio.core.signal")

local requests = {}
local handler_registered = false
local tmp = ffi.new("struct gaicb*[1]")
local sig = ffi.new("struct sigevent")
local next_req_key = 1

local function handle_answer(siginfo)
    assert(siginfo.ssi_code == C.SI_ASYNCNL)
    local key = siginfo.ssi_int
    local req = requests[key]
    if not req then return end
    local gaicb = req.gaicb
    local runp = gaicb.ar_result
    local ip, port
    while runp ~= nil do
        local addr = ffi.cast("struct sockaddr_in *", runp.ai_addr)
        local val = ffi.cast("unsigned short", C.ntohs(addr[0].sin_port))
        port = tonumber(val)
        ip = ffi.string(C.inet_ntoa(addr[0].sin_addr))
        if ip ~= "0.0.0.0" then
            break
        end
        runp = runp.ai_next
    end
    anl.freeaddrinfo(gaicb.ar_result)
    requests[key] = nil
    if req.handler then return req.handler(ip, port) end
    return coroutine.resume(req.co, ip, port)
end

local function resolve(host, port, handler)
    if handler_registered == false then
        handler_registered = true
        signal.add_signal_handler(C.SIGIO, handle_answer)
    end

    local gaicb = ffi.new("struct gaicb")
    assert(requests[next_req_key] == nil)
    local data = {gaicb = gaicb}
    if handler then data.handler = handler
    else data.co = coroutine.running() end
    requests[next_req_key] = data

    gaicb.ar_name = host
    port = (type(port) == "number") and tostring(port) or port
    gaicb.ar_service = port
    sig.sigev_notify = C.SIGEV_SIGNAL
    sig.sigev_value.sival_int = next_req_key
    next_req_key = next_req_key + 1
    sig.sigev_signo = C.SIGIO
    tmp[0] = gaicb
    assert(anl.getaddrinfo_a(C.GAI_NOWAIT, tmp, 1, sig) == 0)

    if handler then return sig.sigev_value.sival_int end
    return coroutine.yield()
end

local function cancel_resolve(key)
    local req = requests[key]
    if req then
        anl.gai_cancel(req.gaicb)
        requests[key] = nil
    end
end

return {
    resolve = resolve,
    cancel_resolve = cancel_resolve,
}
