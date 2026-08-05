# e2e: the chat-header session-config controls (permission mode / model /
# effort) from PR #10, driven BLACK-BOX through the real stack. The mock
# advertises the config blocks in its session/new result (BT_MOCK_ACP_CONFIG=1,
# set by the test's isolated dev_server), so the header renders one native
# <select> per option. We prove, UI-only:
#
#   * bring-up renders a <select> for each config option,
#   * picking the model <select> reflects in the pill (the onchange →
#     apply_config_pick! → session/set_config_option path), and
#   * an agent-driven `config_option_update` mid-turn patches the mode pill
#     WITHOUT splitting the streaming agent bubble.
#
# Isolated (own dev_server): the config blocks would otherwise show up in every
# other suite's header and the picks mutate shared session state.

using Test
isdefined(@__MODULE__, :TestKit) || include(joinpath(@__DIR__, "..", "testkit", "TestKit.jl"))
using .TestKit
const TK = TestKit

# The COMPLETE `configOptions` list with explicit current values — what an agent
# re-emits in a `config_option_update` (the chat REPLACES its config view from
# the full list). Mirrors the mock's `config_blocks()` option shapes.
config_options(; mode = "default", model = "default", effort = "default") = [
    Dict("id"=>"mode", "name"=>"Mode", "category"=>"mode", "type"=>"select",
         "currentValue"=>mode, "options"=>[
            Dict("value"=>"default", "name"=>"Default"),
            Dict("value"=>"plan", "name"=>"Plan"),
            Dict("value"=>"bypassPermissions", "name"=>"Bypass Permissions")]),
    Dict("id"=>"model", "name"=>"Model", "category"=>"model", "type"=>"select",
         "currentValue"=>model, "options"=>[
            Dict("value"=>"default", "name"=>"Default (recommended)",
                 "description"=>"Opus 4.7 with 1M context · Most capable"),
            Dict("value"=>"sonnet", "name"=>"Sonnet", "description"=>"Sonnet 4.6")]),
    Dict("id"=>"effort", "name"=>"Effort", "category"=>"thought_level", "type"=>"select",
         "currentValue"=>effort, "options"=>[
            Dict("value"=>"default", "name"=>"Default"),
            Dict("value"=>"high", "name"=>"High"),
            Dict("value"=>"xhigh", "name"=>"Max")]),
]

# JS that resolves to the header <select> for one config option, identified by
# an option value ONLY that option offers (mode→bypassPermissions, model→sonnet,
# effort→xhigh). Returns the element or undefined.
select_for(marker) =
    "[...document.querySelectorAll('.bt-header-meta .bt-header-meta-select')]" *
    ".find(s => [...s.options].some(o => o.value === $(TK.json(marker))))"

# Read a select's current value (or "" if absent), as a JS expression.
value_of(marker) = "(() => { const s = $(select_for(marker)); return s ? s.value : ''; })()"

function run_suite(server)
    @testset "session config header controls (UI-only)" begin
        # The agent binds lazily on the FIRST message, so a plain turn first
        # makes session/new (and its config blocks) happen. A later "flip" turn
        # streams two chunks with a mid-stream config change (mode →
        # bypassPermissions) between them; model stays `sonnet` so the
        # full-list REPLACE doesn't undo the user's earlier pick.
        server.agent_fn[] = function (prompt)
            occursin("flip", lowercase(prompt)) ?
                [TK.text("hello "),
                 TK.config_update(config_options(mode = "bypassPermissions",
                                                 model = "sonnet", effort = "high")),
                 TK.text("world")] :
                [TK.text("ready")]
        end

        TK.new_chat(server; title = "Cfg")
        # Lazy ACP: the session (and thus the config blocks) binds on the first
        # message, not at chat open — so send one before asserting on the header.
        TK.send_message(server, "bind please")

        @testset "config blocks render one <select> per option after bind" begin
            @test TK.wait_for(server, "3 config selects",
                "document.querySelectorAll('.bt-header-meta .bt-header-meta-select').length === 3";
                timeout = 30) == true
            for marker in ("bypassPermissions", "sonnet", "xhigh")
                @test TK.eval_js(server, "!!($(select_for(marker)))") == true
            end
            # Initial permission mode is the session's reported default.
            @test TK.eval_js(server, "$(value_of("bypassPermissions")) === 'default'") == true
        end

        @testset "picking the model reflects in its pill" begin
            picked = TK.eval_js(server, """(() => {
                const s = $(select_for("sonnet"));
                if (!s) return false;
                s.value = "sonnet";
                s.dispatchEvent(new Event("change", { bubbles: true }));
                return true;
            })()""")
            @test picked == true
            # apply_config_pick! optimistically patches session_meta; the meta
            # line re-renders with sonnet selected.
            @test TK.wait_for(server, "model pill = sonnet",
                "$(value_of("sonnet")) === 'sonnet'"; timeout = 15) == true
        end

        @testset "agent config_option_update patches mode mid-turn, bubble intact" begin
            TK.send_message(server, "flip it")
            # the mid-stream config_option_update flips the mode pill…
            @test TK.wait_for(server, "mode pill = bypassPermissions",
                "$(value_of("bypassPermissions")) === 'bypassPermissions'"; timeout = 30) == true
            # …the earlier model pick survives the full-list replace…
            @test TK.eval_js(server, "$(value_of("sonnet")) === 'sonnet'") == true
            # …and the two streamed chunks are ONE bubble, not split by the update.
            @test TK.wait_for(server, "single 'hello world' bubble",
                "[...document.querySelectorAll('.bt-agent-msg')]" *
                ".filter(b => (b.innerText||'').includes('hello world')).length === 1";
                timeout = 15) == true
        end
    end
end
