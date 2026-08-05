@testitem "unit:ram_bounds" tags = [:unit] begin

# RAM-bounding regression guards: the in-RAM tool-content cache must not grow
# without limit on a marathon chat. Every cached body is also on disk
# (persist_tool_content!), so once the cache passes its cap the OLDEST non-empty
# bodies are evicted (re-read from disk on demand) while the live/recent ones and
# the authoritative empty markers stay. Pure unit test — no worker, no browser.

using Test
import BonitoAgents
const BT = BonitoAgents

newstate() = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(),
                            worker_secret = "x")

@testset "tool_content_cache is LRU-bounded" begin
    cap = BT.TOOL_CONTENT_CACHE_CAP
    st = newstate(); cwd = mktempdir()
    # A chat always has an agent now (no local-default); a WorkerAgent is a plain
    # struct — nothing connects until `start!`, which this cache test never calls.
    m = BT.ChatModel(st, cwd; project_id = "p", agent = BT.WorkerAgent(st, "w", cwd))
    cache, order = m.tool_content_cache, m.tool_cache_order

    # Fill well past the cap with completed (non-empty) tools, then a couple of
    # live (empty) tools.
    for i in 1:(cap + 64); BT.cache_tool_content!(m, "tool-$i", Any["body-$i"]); end
    BT.cache_tool_content!(m, "live-a", Any[])
    BT.cache_tool_content!(m, "live-b", Any[])

    @test length(cache) == cap                 # hard-bounded, never grows past the cap
    @test length(order) == cap                 # the recency list is bounded too (no dup growth)
    @test haskey(cache, "tool-$(cap + 64)")    # most-recent body kept (fast path)
    @test haskey(cache, "tool-$(cap + 60)")    # a recent body kept
    @test !haskey(cache, "tool-1")             # oldest body evicted → falls back to disk
    @test !haskey(cache, "tool-30")
    @test haskey(cache, "live-a") && haskey(cache, "live-b")   # empties (live markers) kept

    # Re-caching an older tool promotes it to most-recent (and it survives).
    BT.cache_tool_content!(m, "tool-100", Any["refreshed"])
    @test haskey(cache, "tool-100")
    @test length(cache) == cap                 # still bounded
end

end
