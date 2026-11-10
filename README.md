# SmsGora.jl

[![CI](https://github.com/TekservixHQ/SmsGora.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/TekservixHQ/SmsGora.jl/actions/workflows/CI.yml)

Julia client for the [SMS Gora SMS Gateway](https://tekservix.com/smsgora/) API.

SMS Gora turns Android phones with ordinary SIM cards into an SMS gateway. Your code calls the API, a linked phone sends the text, and replies and delivery reports come back to you. Useful for alerts from simulations, lab equipment, trading or monitoring scripts. There's no sender ID registration and no per-message fee from us: your mobile operator bills the texts like any SMS.

## Install

```julia
using Pkg
Pkg.add("SmsGora")
```

Julia 1.6+.

## Quick start

You need a Tekservix account with SMS Gora and an API key (SMS Gora → API keys). Keep it out of shared notebooks.

```julia
using SmsGora

client = SmsGora.Client(ENV["SMSGORA_KEY"])

result = send_sms(client, "+15551234567", "Your simulation finished: loss 0.031")
result["message_ids"]   # [1873]
```

## Sending

```julia
using Dates

# Several recipients (up to 1,000 per call)
send_sms(client, ["+15551234567", "+447700900123"], "Server CPU above 90%")

# From a chosen phone and SIM, scheduled for later
send_sms(client, "+15551234567", "Reminder: meeting at 10:00";
         device_id = 42, sim_slot = 1, schedule_at = DateTime(2026, 12, 1, 8))

# Different texts for different people in one call (up to 5,000 recipients)
send_bulk_sms(client, 42, [
    Dict("recipients" => ["+15551234567"], "message" => "Hi Aline, parcel #1042 is ready."),
    Dict("recipients" => ["+15557654321"]),
]; message_template = "Hello, your parcel is ready for pickup.")
```

## Status and incoming SMS

```julia
msg = get_message(client, 1873)
msg["status"]                       # queued, dispatched, sent, delivered or failed

cancel_message(client, 1874)        # while queued or scheduled
inbox = list_received_sms(client; since = "2026-11-01", limit = 50)
phones = list_devices(client)
account = get_account(client)
SmsGora.request(client, "GET", "/batches/311")   # any other endpoint
```

## Webhooks

Each webhook request carries `X-SmsGora-Signature: sha256=...`, an HMAC-SHA256 of the raw body. With HTTP.jl:

```julia
using HTTP
HTTP.serve("0.0.0.0", 8080) do req
    sig = HTTP.header(req, "X-SmsGora-Signature")
    verify_webhook(String(copy(req.body)), sig, ENV["SMSGORA_WEBHOOK_SECRET"]) || return HTTP.Response(401)
    # event = JSON3.read(req.body); event.data.from, event.data.message
    HTTP.Response(200, "ok")
end
```

## Errors

Failed calls throw `SmsGoraError` with `status`, `message`, `errors`, `body` and `retry_after` (seconds, on 429).

## More from Tekservix

- [WAservix WhatsApp API Gateway](https://tekservix.com/waservix/): WhatsApp from your own number (`Pkg.add("WAservix")`)
- [AI Sales Agent](https://tekservix.com/ai-sales-agent): answers customers on WhatsApp and SMS using your website's content
- [Website to App](https://tekservix.com/mobile-apps): turn your website into Android and iOS apps
- SMS Gora libraries for many more languages: [github.com/TekservixHQ](https://github.com/TekservixHQ)

## License

MIT
