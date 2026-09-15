# Every sidebar icon wears a ring in its machine's colour, so a picture icon
# still says where the chat runs after the worker initials moved into the
# tooltip. The colour is a function of the worker's install id alone: the same
# on every server, after every restart, and untouched by renames.
@testitem "unit:worker_color" tags = [:unit] begin
    import BonitoAgents
    const BT = BonitoAgents
    using Test

    a = BT.worker_color("f2a1c9d0-6b3e-4d2a-9c1f-worker")
    @test a == BT.worker_color("f2a1c9d0-6b3e-4d2a-9c1f-worker")
    # Perceptual lightness and chroma are fixed and only the hue moves, so
    # every machine's ring carries the same visual weight.
    @test occursin(r"^oklch\(52% 0\.19 \d+\)$", a)
    @test a != BT.worker_color("another-install")
    @test length(Set(BT.worker_color("install-$i") for i in 1:40)) >= 30
end
