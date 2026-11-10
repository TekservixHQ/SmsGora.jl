"""
    SmsGora

Julia client for the [SMS Gora SMS Gateway](https://tekservix.com/smsgora/) API.

SMS Gora turns Android phones with ordinary SIM cards into an SMS gateway: your server
calls the API, a linked phone sends the text, and replies and delivery reports come back.

```julia
using SmsGora
client = SmsGora.Client(ENV["SMSGORA_KEY"])
result = send_sms(client, "+15551234567", "Your code is 482913")
result["message_ids"]   # [1873]
```

You need a Tekservix account with SMS Gora and an API key (SMS Gora → API keys).
Keep it on your server. API reference: https://tekservix.com/smsgora/docs/
"""
module SmsGora

using Dates
using HTTP
using JSON3
using SHA

export send_sms, send_bulk_sms, get_message, cancel_message, list_messages, list_received_sms,
    get_batch, list_devices, get_device, get_account, list_webhooks, create_webhook,
    delete_webhook, verify_webhook, SmsGoraError

const PKG_VERSION = "1.0.0"
const DEFAULT_BASE_URL = "https://tekservix.com/smsgora/api/v1"

"""
    SmsGoraError

Thrown when the API answers with an error. Fields: `status` (0 if the request never
reached the API), `message`, `errors`, `body`, `retry_after` (seconds, on 429).
"""
struct SmsGoraError <: Exception
    status::Int
    message::String
    errors::Any
    body::Any
    retry_after::Union{Nothing,Float64}
end

Base.showerror(io::IO, e::SmsGoraError) = print(io, "SmsGora: ", e.message, " (HTTP ", e.status, ")")

function default_transport(method, url, headers, body)
    res = HTTP.request(method, url, headers, body === nothing ? UInt8[] : body;
        status_exception = false, retry = false, readtimeout = 30)
    return res.status, String(res.body), Dict(lowercase(String(k)) => String(v) for (k, v) in res.headers)
end

"""
    SmsGora.Client(api_key; base_url = DEFAULT_BASE_URL, transport = default_transport)

`transport(method, url, headers, body) -> (status, body, headers)` can be replaced for tests or proxies.
"""
struct Client
    api_key::String
    base_url::String
    transport::Function
end

function Client(api_key::AbstractString; base_url::AbstractString = DEFAULT_BASE_URL, transport::Function = default_transport)
    isempty(api_key) && throw(ArgumentError("SmsGora: api_key is required (create one in SMS Gora → API keys)"))
    return Client(String(api_key), rstrip(String(base_url), '/'), transport)
end

esc(x) = HTTP.URIs.escapeuri(string(x))

function query(params)
    pairs = [(string(k), string(v)) for (k, v) in params if v !== nothing && string(v) != ""]
    isempty(pairs) && return ""
    sort!(pairs; by = first)
    return "?" * join([esc(k) * "=" * esc(v) for (k, v) in pairs], "&")
end

"""
    request(client, method, path, body = nothing)

Call any documented endpoint, e.g. `SmsGora.request(client, "GET", "/devices")`. Returns the `data` field.
"""
function request(c::Client, method::AbstractString, path::AbstractString, body = nothing)
    headers = [
        "x-api-key" => c.api_key,
        "Accept" => "application/json",
        "User-Agent" => "smsgora-julia/$PKG_VERSION",
    ]
    payload = nothing
    if body !== nothing
        push!(headers, "Content-Type" => "application/json")
        payload = JSON3.write(body)
    end
    status, text, resp_headers = try
        c.transport(uppercase(method), c.base_url * path, headers, payload)
    catch err
        throw(SmsGoraError(0, "request failed: " * sprint(showerror, err), nothing, nothing, nothing))
    end
    data = isempty(text) ? nothing : (try JSON3.read(text) catch; nothing end)
    isobj = data isa JSON3.Object
    if status >= 400 || (isobj && get(data, :success, true) === false)
        msg = isobj && get(data, :message, nothing) isa AbstractString ? String(data[:message]) : "HTTP $status"
        retry = get(resp_headers, "retry-after", nothing)
        throw(SmsGoraError(status, msg, isobj ? get(data, :errors, nothing) : nothing,
            data === nothing ? text : data, retry === nothing ? nothing : tryparse(Float64, retry)))
    end
    return isobj && haskey(data, :data) ? data[:data] : data
end

"""
    send_sms(client, to, message; device_id = nothing, sim_slot = nothing, schedule_at = nothing)

Send an SMS to one number or a vector (up to 1,000). `sim_slot`: 0 = SIM 1, 1 = SIM 2.
`schedule_at`: a `DateTime` (UTC) or ISO 8601 string. Returns `{"message_ids": [...]}`.
"""
function send_sms(c::Client, to, message::AbstractString; device_id = nothing, sim_slot = nothing, schedule_at = nothing)
    recipients = to isa AbstractString ? [String(to)] : String.(collect(to))
    isempty(recipients) && throw(ArgumentError("send_sms: at least one recipient is required"))
    body = Dict{String,Any}("recipients" => recipients, "message" => message)
    sim_slot === nothing || (body["sim_slot"] = sim_slot)
    if schedule_at !== nothing
        body["schedule_at"] = schedule_at isa DateTime ? Dates.format(schedule_at, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z" : string(schedule_at)
    end
    path = device_id === nothing ? "/send-sms" : "/devices/$(esc(device_id))/send-sms"
    return request(c, "POST", path, body)
end

"""
    send_bulk_sms(client, device_id, messages; message_template = nothing)

Different texts for different people in one call (up to 5,000 recipients).
`messages` is a vector of `Dict("recipients" => [...], "message" => "own text")`.
"""
function send_bulk_sms(c::Client, device_id, messages; message_template = nothing)
    body = Dict{String,Any}("messages" => messages)
    message_template === nothing || (body["messageTemplate"] = message_template)
    return request(c, "POST", "/devices/$(esc(device_id))/send-bulk-sms", body)
end

"Status is queued, dispatched, sent, delivered, failed or cancelled."
get_message(c::Client, id) = request(c, "GET", "/messages/$(esc(id))")
"Cancel a queued or scheduled message."
cancel_message(c::Client, id) = request(c, "POST", "/messages/$(esc(id))/cancel")
"Filters: direction, status, device_id, phone, since, after_id, page, limit."
list_messages(c::Client; filters...) = request(c, "GET", "/messages" * query(filters))

"Incoming SMS for all phones, or one phone with `device_id`."
function list_received_sms(c::Client; device_id = nothing, filters...)
    path = device_id === nothing ? "/received-sms" : "/devices/$(esc(device_id))/get-received-sms"
    return request(c, "GET", path * query(filters))
end

get_batch(c::Client, id) = request(c, "GET", "/batches/$(esc(id))")
"Your linked Android phones."
list_devices(c::Client) = request(c, "GET", "/devices")
get_device(c::Client, id) = request(c, "GET", "/devices/$(esc(id))")
"Account, plan and usage."
get_account(c::Client) = request(c, "GET", "/account")
list_webhooks(c::Client) = request(c, "GET", "/webhooks")

"Register a webhook (events default to `sms.received`). The answer includes the secret, returned once."
create_webhook(c::Client, url::AbstractString; events = ["sms.received"], device_id = nothing) =
    request(c, "POST", "/webhooks", Dict("url" => url, "events" => events, "device_id" => device_id))

delete_webhook(c::Client, id) = request(c, "DELETE", "/webhooks/$(esc(id))")

"""
    verify_webhook(raw_body, signature, secret) -> Bool

Check the `X-SmsGora-Signature` header (`sha256=<hex HMAC-SHA256 of the raw body>`) in constant time.
"""
function verify_webhook(raw_body, signature, secret)
    (raw_body === nothing || signature === nothing || secret === nothing) && return false
    (isempty(raw_body) || isempty(signature) || isempty(secret)) && return false
    body = raw_body isa AbstractVector{UInt8} ? Vector{UInt8}(raw_body) : Vector{UInt8}(codeunits(String(raw_body)))
    expected = "sha256=" * bytes2hex(hmac_sha256(Vector{UInt8}(codeunits(String(secret))), body))
    a, b = codeunits(expected), codeunits(String(signature))
    length(a) == length(b) || return false
    diff = 0x00
    for i in eachindex(a)
        diff |= a[i] ⊻ b[i]
    end
    return diff == 0x00
end

end # module
