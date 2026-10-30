@testitem "unit:app_widgets" tags = [:unit] begin
    using Bonito
    using BonitoAgents: AppButton, AppCard, AppModal

    html(node) = repr(MIME"text/html"(), node)
    disabled = Observable(false)
    button = AppButton("Publish"; variant = :secondary, size = :small,
                       dataAct = "publish", disabled)
    session = Bonito.Session()
    try
        rendered = html(Bonito.jsrender(session, AppCard(button; class = "plugin-release")))
        @test occursin("plugin-release", rendered)
        @test occursin("bw-btn-secondary", rendered)
        @test occursin("data-act=\"publish\"", rendered)
        disabled[] = true
        @test disabled[]

        # Body construction follows the shared modal lifecycle, including
        # opening again after close (forms must not reuse their prior values).
        opened = Observable(false)
        builds = Ref(0)
        modal = AppModal(opened; title = "Credentials") do
            builds[] += 1
            DOM.input(; type = "password", value = "")
        end
        Bonito.jsrender(session, modal)
        @test builds[] == 0
        opened[] = true
        @test builds[] == 1
        opened[] = false
        opened[] = true
        @test builds[] == 2
    finally
        close(session)
    end
end
