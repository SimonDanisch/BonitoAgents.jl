# Which machine a chat runs on must be readable on EVERY sidebar icon, and there
# is ONE icon: a picture (the chat's own, or a generated identicon) with the
# worker's initials as a badge and the worker's full name in the tooltip. The
# badge slot is the worker's alone: no folder initials ever stand in for it
# (a tile once read "VU" for VulkanDev, 2026-09-15).
@testitem "unit:project_icon_tag" tags = [:unit] begin
    import BonitoAgents
    using Bonito
    const BT = BonitoAgents
    using Test

    html(node) = repr(MIME"text/html"(), node)
    badge(h) = match(r"class=\"bt-proj-tag\">([^<]*)<", h)[1]
    title(h) = match(r"title=\"([^\"]*)\"", h)[1]

    tile = html(BT.project_icon_for("p1", "VulkanDev", "VulkanDev", "L", "Laptop"))
    @test occursin("class=\"bt-proj-icon\"", tile)
    @test occursin("src=\"data:image/svg+xml;base64,", tile)      # the identicon is an image too
    @test badge(tile) == "L"
    @test title(tile) == "Laptop · VulkanDev"

    dir = mktempdir()
    pic = joinpath(dir, "icon.svg")
    write(pic, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"/>")
    picture = html(BT.project_icon_for("p1", "VulkanDev", "VulkanDev", "L", "Laptop"; image = Bonito.Asset(pic)))
    @test occursin("class=\"bt-proj-icon bt-proj-icon-img\"", picture)
    @test badge(picture) == "L"
    @test title(picture) == "Laptop · VulkanDev"
    # Same markup either way: the only difference is the image source and the marker class.
    strip_src(h) = replace(replace(h, r"src=\"[^\"]*\"" => "src=X"), " bt-proj-icon-img" => "")
    @test strip_src(tile) == strip_src(picture)

    # No stand-ins: an icon without its worker is a programming error, not "VU".
    @test_throws ArgumentError BT.project_icon_for("p1", "VulkanDev", "VulkanDev", "", "Laptop")
    @test_throws ArgumentError BT.project_icon_for("p1", "VulkanDev", "VulkanDev", "L", "")

    # The label comes from the worker record; a worker the server does not know
    # is named by its id, never by the folder.
    state = BT.ServerState(; state_dir = mktempdir(), working_dir = mktempdir(), worker_secret = "x")
    state.workers[]["w-lap"] = BT.WorkerInfo("w-lap", "Laptop", "ws://x", "x", nothing, "host", "/home/u",
                                             "julia", String[], "/sim", :online, BT.now(BT.UTC))
    state.workers[]["w-lap"].initials = "L"
    p = BT.ProjectInfo("p1", "VulkanDev", "w-lap", joinpath(state.working_dir, "p1"), "/sim/VulkanDev", BT.now(BT.UTC))
    @test BT.worker_label(state, p) == ("L", "Laptop")
    orphan = BT.ProjectInfo("p2", "VulkanDev", "gone-worker", joinpath(state.working_dir, "p2"), "/sim/VulkanDev", BT.now(BT.UTC))
    @test BT.worker_label(state, orphan) == (BT.derive_initials("gone-worker"), "gone-worker")
    @test badge(html(BT.project_icon(state, p))) == "L"
end
