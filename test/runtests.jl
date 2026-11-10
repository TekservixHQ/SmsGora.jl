using SmsGora
using Test
using Dates
using JSON3

mutable struct Recorder
    calls::Vector{Any}
    status::Int
    reply::String
    headers::Dict{String,String}
end
Recorder() = Recorder([], 200, """{"success":true,"data":{"message_ids":[1873]}}""", Dict{String,String}())

function client(r::Recorder; base = "https://example.test/api/")
    transport = (method, url, headers, body) -> begin
        push!(r.calls, (method = method, url = url, headers = Dict(headers), body = body === nothing ? nothing : JSON3.read(body)))
        (r.status, r.reply, r.headers)
    end
    return SmsGora.Client("sgk_test"; base_url = base, transport = transport)
end

@testset "SmsGora" begin
    @testset "send_sms" begin
        r = Recorder(); c = client(r)
        res = send_sms(c, "+15551234567", "Hi")
        @test res["message_ids"][1] == 1873
        @test r.calls[1].method == "POST"
        @test r.calls[1].url == "https://example.test/api/send-sms"
        @test r.calls[1].headers["x-api-key"] == "sgk_test"
        @test collect(r.calls[1].body["recipients"]) == ["+15551234567"]
        @test r.calls[1].body["message"] == "Hi"
        @test !haskey(r.calls[1].body, "sim_slot")

        send_sms(c, ["+1", "+2"], "x"; device_id = 42, sim_slot = 1, schedule_at = DateTime(2026, 12, 1, 8))
        @test r.calls[2].url == "https://example.test/api/devices/42/send-sms"
        @test r.calls[2].body["sim_slot"] == 1
        @test r.calls[2].body["schedule_at"] == "2026-12-01T08:00:00Z"
        @test_throws ArgumentError send_sms(c, String[], "x")
        @test_throws ArgumentError SmsGora.Client("")
    end

    @testset "paths" begin
        r = Recorder(); c = client(r; base = "https://example.test/api")
        send_bulk_sms(c, 42, [Dict("recipients" => ["+1"], "message" => "a"), Dict("recipients" => ["+2"])]; message_template = "t")
        @test r.calls[1].url == "https://example.test/api/devices/42/send-bulk-sms"
        @test r.calls[1].body["messageTemplate"] == "t"
        list_received_sms(c; phone = "+1555", since = "2026-11-01")
        @test r.calls[2].url == "https://example.test/api/received-sms?phone=%2B1555&since=2026-11-01"
        list_received_sms(c; device_id = 3)
        @test r.calls[3].url == "https://example.test/api/devices/3/get-received-sms"
        cancel_message(c, 7)
        @test r.calls[4].url == "https://example.test/api/messages/7/cancel"
        create_webhook(c, "https://my.app/hook")
        @test collect(r.calls[5].body["events"]) == ["sms.received"]
        delete_webhook(c, 9)
        @test r.calls[6].method == "DELETE"
    end

    @testset "errors" begin
        r = Recorder()
        r.status = 429
        r.reply = """{"success":false,"message":"Too many requests","errors":{"recipients":["bad"]}}"""
        r.headers = Dict("retry-after" => "12")
        err = try get_account(client(r)); nothing catch e; e end
        @test err isa SmsGoraError
        @test err.status == 429
        @test err.message == "Too many requests"
        @test err.retry_after == 12.0
        @test err.errors["recipients"][1] == "bad"
        @test occursin("Too many requests (HTTP 429)", sprint(showerror, err))

        r2 = Recorder(); r2.status = 502; r2.reply = "<html>bad gateway</html>"
        err2 = try list_devices(client(r2)); nothing catch e; e end
        @test err2.message == "HTTP 502"
        @test err2.body == "<html>bad gateway</html>"
    end

    @testset "webhook" begin
        raw = """{"event":"sms.received","data":{"from":"+15551234567"}}"""
        sig = "sha256=e125c07dfbecb498e8979383d7b9f0815efb128755409794b486d4bbb7199583"
        @test verify_webhook(raw, sig, "whsec_test")
        @test verify_webhook(Vector{UInt8}(raw), sig, "whsec_test")
        @test !verify_webhook(raw, sig, "other")
        @test !verify_webhook("{}", sig, "whsec_test")
        @test !verify_webhook(raw, nothing, "whsec_test")
    end
end
