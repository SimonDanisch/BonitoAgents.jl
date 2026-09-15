# The connection guard renders closed, with everything the JS flips later
# already in the DOM: the LED, the modal with its message, and the reload
# button. Nothing is injected mid-failure, when the server is out of reach.
@testitem "unit:connection_guard" tags = [:unit] begin
    import BonitoAgents
    using Bonito
    const BT = BonitoAgents
    using Test

    session = Bonito.Session()
    html = repr(MIME"text/html"(), Bonito.jsrender(session, BT.connection_guard(session)))
    @test occursin("class=\"bt-conn-led\"", html)
    @test occursin("class=\"bt-conn-modal\"", html)
    @test !occursin("bt-conn-open", html)                 # closed until the JS says otherwise
    @test occursin("class=\"bt-conn-msg\"", html)
    @test occursin("Reload page", html)
    @test occursin("bt-conn-elapsed", html)
    @test occursin("role=\"alertdialog\"", html)
end
