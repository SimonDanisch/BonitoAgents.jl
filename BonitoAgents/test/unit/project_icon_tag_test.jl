# Which machine a chat runs on must be readable on EVERY sidebar icon, and there
# is ONE icon: a picture (the chat's own, or a generated identicon) with the
# worker's initials as a badge. Two hand-rolled forms once drifted apart and the
# badge went missing from picture icons (2026-09-15).
@testitem "unit:project_icon_tag" tags = [:unit] begin
    import BonitoAgents
    using Bonito
    const BT = BonitoAgents
    using Test

    html(node) = repr(MIME"text/html"(), node)
    badge(h) = match(r"class=\"bt-proj-tag\">([^<]*)<", h)

    tile = html(BT.project_icon_for("p1", "HOTS", "HOTS", "MA"))
    @test occursin("class=\"bt-proj-icon\"", tile)
    @test occursin("src=\"data:image/svg+xml;base64,", tile)      # the identicon is an image too
    @test badge(tile)[1] == "MA"

    dir = mktempdir()
    pic = joinpath(dir, "icon.svg")
    write(pic, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"/>")
    picture = html(BT.project_icon_for("p1", "HOTS", "HOTS", "MA"; image = Bonito.Asset(pic)))
    @test occursin("class=\"bt-proj-icon bt-proj-icon-img\"", picture)
    @test badge(picture)[1] == "MA"
    # Same markup either way: the only difference is the image source and the marker class.
    strip_src(h) = replace(replace(h, r"src=\"[^\"]*\"" => "src=X"), " bt-proj-icon-img" => "")
    @test strip_src(tile) == strip_src(picture)

    # Without a worker the badge falls back to the folder's initials, on both.
    @test badge(html(BT.project_icon_for("p1", "HOTS", "HOTS")))[1] == "HO"
    @test badge(html(BT.project_icon_for("p1", "HOTS", "HOTS"; image = Bonito.Asset(pic))))[1] == "HO"
end
