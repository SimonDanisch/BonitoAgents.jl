# Every sidebar icon wears a ring in its machine's colour, so a picture icon
# still says where the chat runs after the worker initials moved into the
# tooltip. Each worker holds a slot in a palette of mutually distant colours,
# persisted, so its colour survives restarts and renames and does not change
# when other workers come and go.
@testitem "unit:worker_color" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    const Colors = BT.Colors
    using Test

    # Distinct, valid CSS colours, and the palette for n is the start of the
    # one for more: a new worker never recolors the others.
    @test occursin(r"^#[0-9A-F]{6}$", BT.worker_color(0))
    @test length(Set(BT.worker_color(slot) for slot in 0:23)) == 24
    @test BT.worker_palette(12)[1:6] == BT.worker_palette(6)
    @test [BT.worker_color(slot) for slot in 0:5] == ["#" * Colors.hex(c) for c in BT.worker_palette(6)]

    # The real fleet: six machines, which a hash of their ids put within 10
    # degrees of hue for three of them. With a slot each, every pair is
    # clearly apart (CIEDE2000 around 20 is an obvious difference).
    six = BT.worker_palette(6)
    @test minimum(Colors.colordiff(six[i], six[j]) for i in 1:6 for j in (i+1):6) > 20
    # Mostly the hue moves: no ring much darker or lighter than the rest (teals,
    # outside the screen's gamut at full chroma, come out a little lighter).
    @test all(c -> 54 <= c.l <= 60, Colors.LCHab.(BT.worker_palette(24)))

    # Slots: the lowest free one; a removed worker's slot is reused.
    mk(id, slot) = (w = BT.WorkerInfo(id, id, nothing, id, "/home/u", "julia", String[], "/p", :online, BT.now(BT.UTC));
                    w.color_slot = slot; w)
    workers = Dict("a" => mk("a", 0), "b" => mk("b", 1), "d" => mk("d", 3))
    @test BT.free_color_slot(workers, "new") == 2
    workers["c"] = mk("c", 2)
    @test BT.free_color_slot(workers, "new") == 4
    @test BT.free_color_slot(workers, "b") == 1     # a worker's own slot counts as free for it

    # A chat on a worker the server does not know is neutral, not some other
    # machine's colour.
    @test BT.worker_color(workers, "gone") == "#9ca3af"
    @test BT.worker_color(workers, "c") == BT.worker_color(2)

    # Persisted: a reload keeps every slot; workers saved before slots existed
    # get the lowest free ones, in name order.
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir())
    for (id, slot) in (("w-desk", 4), ("w-mac", 0))
        state.workers[][id] = mk(id, slot)
    end
    BT.save_workers!(state)
    legacy = BT.JSON.parsefile(BT.workers_file(state))
    push!(legacy, Dict("worker_id" => "w-old-b", "name" => "Bosgame"),
                  Dict("worker_id" => "w-old-a", "name" => "Attic"))
    open(io -> BT.JSON.print(io, legacy), BT.workers_file(state), "w")
    reloaded = BT.ServerState(; state_dir = state.state_dir, working_dir = mktempdir())
    empty!(reloaded.workers[])
    BT.load_workers!(reloaded)
    slots = Dict(id => w.color_slot for (id, w) in reloaded.workers[])
    @test slots == Dict("w-desk" => 4, "w-mac" => 0, "w-old-a" => 1, "w-old-b" => 2)
    # ...and that assignment was written back.
    @test Dict(String(d["worker_id"]) => d["color_slot"] for d in BT.JSON.parsefile(BT.workers_file(reloaded))) == slots
end
