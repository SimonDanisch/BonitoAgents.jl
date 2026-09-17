# Seed the walkthrough rig: the four REAL chats both recorders replay.
#
# The rig lives outside the repo (`BT_WALKTHROUGH_RIG`, default
# `../../../walkthrough`) and holds machine-local absolute paths, so it cannot be
# committed — which means a fresh checkout, or a machine that lost the directory,
# has no chats to record and `walkthrough_dashboard.jl` dies on
# `KeyError: "GameOfLife"`. This script rebuilds it.
#
# It is the ONLY step that spends tokens: each chat below is a real
# claude-agent-acp turn. Re-recording afterwards replays from disk and spends
# none, which is the whole point of the rig.
#
# What each chat has to end up containing — the recorders depend on it:
#
#   LorenzExplorer  a `lorenz.jl` in the project (the tour opens it from the file
#                   tree) and a bt_julia_eval that RETURNS a Bonito App with a
#                   rho slider (the tour steers it, detaches it into the
#                   plotpane, and relies on the keep-alive remount).
#   FractalGallery  several rendered images shown into the chat — the dashboard
#                   cards take their thumbnails from a chat's own pictures.
#   GameOfLife      an edit with a real diff, so the card shows a refactor and
#                   the tour can flip through Monaco content.
#   TinyServer      a parallel review driven by SUBAGENTS, for the subagent
#                   activity feed the tour pans across.
#
#   julia --project=/sim/Programmieren/AgentsDev examples/walkthrough_seed.jl
#   julia --project=/sim/Programmieren/AgentsDev examples/walkthrough_seed.jl LorenzExplorer
#
# Naming one seed on the command line reseeds just that chat (its project is
# recreated), which is how you iterate when one prompt came back thin without
# paying for the other three again.
isdefined(@__MODULE__, :tour) || include(joinpath(@__DIR__, "walkthrough.jl"))

# The eval env the demo evals run in: a normal user project that already has
# Bonito + WGLMakie, exactly as a user's would.
const SEED_EVAL_ENV = get(ENV, "BT_WALKTHROUGH_EVAL_ENV", "/sim/Programmieren/ClaudeExperiments")

"""
One chat to seed: the project folder's name, what the agent is asked, and the
check that says the turn actually produced what the tour needs. `verify` runs
against the chat's stored messages after the turn settles.
"""
struct Seed
    name::String
    files::Dict{String,String}   # seeded into the project BEFORE the turn
    prompt::String
    verify::Function
end

# ── what "this chat is usable on camera" means, per chat ──────────────────────
has_shown_image(msgs) = any(msgs) do m
    m isa BT.ToolMsg || return false
    c = BT.tool_content_for_render(m, "")
    isempty(c) && return false
    ref = BT.find_show_reference(c)
    ref !== nothing && any(endswith(lowercase(BT.parse_show_path(ref)), e)
                           for e in (".png", ".jpg", ".jpeg"))
end
has_eval_app(msgs)  = any(m -> m isa BT.JuliaEvalCall && !isempty(m.code), msgs)
has_diff_edit(msgs) = any(m -> m isa BT.EditToolMsg, msgs)
has_subagents(msgs) = any(m -> m isa BT.TaskToolMsg, msgs)

const SEEDS = [
    Seed("LorenzExplorer",
         Dict("lorenz.jl" => """
             # The Lorenz system, integrated with a fixed-step RK4 so the demo is
             # reproducible frame to frame.
             function lorenz_step(u, dt; sigma = 10.0, rho = 28.0, beta = 8 / 3)
                 x, y, z = u
                 dx = sigma * (y - x)
                 dy = x * (rho - z) - y
                 dz = x * y - beta * z
                 return (x + dt * dx, y + dt * dy, z + dt * dz)
             end

             function trajectory(; n = 20_000, dt = 0.002, u0 = (1.0, 1.0, 1.0), rho = 28.0)
                 u = u0
                 pts = Vector{typeof(u0)}(undef, n)
                 for i in 1:n
                     u = lorenz_step(u, dt; rho = rho)
                     pts[i] = u
                 end
                 return pts
             end
             """),
         "Read lorenz.jl, then use bt_julia_eval (env_path = \"$(SEED_EVAL_ENV)\") to build " *
         "and RETURN an interactive visit-density explorer as a Bonito App: a rho " *
         "Slider(10:60) driving an Axis3 density surface of the attractor, recomputed in " *
         "the worker on every drag. Return the App as the LAST expression so it renders " *
         "live in the chat. Keep the prose to one sentence.",
         msgs -> has_eval_app(msgs)),

    Seed("FractalGallery",
         Dict{String,String}(),
         "Use bt_julia_eval (env_path = \"$(SEED_EVAL_ENV)\") to render a small gallery of " *
         "Julia sets: four 600x600 images at c = -0.4+0.6im, 0.285+0.01im, -0.8+0.156im and " *
         "-0.70176-0.3842im, each saved as a PNG next to the project and shown in the chat " *
         "with bt_show. One sentence of prose, then the images.",
         has_shown_image),

    # The starting file is `LIFE_JL_FLAT` from walkthrough.jl, which the chat
    # still re-runs this same refactor against — one definition for both.
    Seed("GameOfLife",
         Dict("life.jl" => LIFE_JL_FLAT),
         "Refactor life.jl so the grid wraps as a torus (a glider leaving the right edge " *
         "re-enters on the left), using mod1 for the neighbour lookup, and keep the " *
         "function's signature. Edit the file, don't paste it into the chat.",
         has_diff_edit),

    Seed("TinyServer",
         Dict("server.jl" => """
             # A deliberately rough little HTTP server: three routes, no input
             # validation, a global cache nobody bounds, and a handler that swallows
             # every error. Material for a review.
             const CACHE = Dict{String,Any}()

             route(path) = path == "/health" ? (200, "ok") :
                           path == "/cache"  ? (200, string(length(CACHE))) :
                           (404, "not found")

             function handle(req)
                 try
                     code, body = route(req.path)
                     CACHE[req.path] = body
                     return (code, body)
                 catch
                     return (500, "")
                 end
             end
             """),
         "Review server.jl on three axes IN PARALLEL, one subagent each: error handling, " *
         "unbounded state, and input validation. Launch them as concurrent Task subagents " *
         "and summarise their findings in one short list when they are all back.",
         has_subagents),
]

# ── seeding ───────────────────────────────────────────────────────────────────
"Project folder for a seed, under the rig worker's own projects root."
seed_dir(server, s::Seed) = joinpath(server.h.worker_root, s.name)

"Create the folder + its starting files, replacing whatever was there."
function lay_out!(server, s::Seed)
    dir = seed_dir(server, s)
    rm(dir; recursive = true, force = true)
    mkpath(dir)
    for (name, body) in s.files
        write(joinpath(dir, name), body)
    end
    return dir
end

"Register the folder as a project and bind its session."
function register!(server, s::Seed, dir)
    state = server.h.state
    wid = first(keys(state.workers[]))
    # Drop a previous project of the same name — `rig_pids` keys on the name, so
    # two of them would make the lookup pick whichever hashed first. There is no
    # `remove_project!`; the server deletes inline like `prune_missing_projects!`.
    lock(state.lock) do
        for (id, p) in collect(state.projects[])
            p.name == s.name || continue
            delete!(state.projects[], id)
            delete!(state.review_states, id)
        end
        BT.save_projects!(state)
    end
    BT.notify_projects!(state)
    return BT.create_project_from_worker!(state, wid, dir; name = s.name, start_session = true)
end

"""
Send the seed prompt and wait for the turn to actually finish.

The budget is generous on purpose. These turns load Bonito + WGLMakie in a cold
eval worker and then build an app, which is minutes before the agent has said
anything worth filming — and the caller CLOSES the rig when this returns, so a
short budget doesn't just truncate the wait, it kills the eval in flight and
writes a `failed` tool with empty content into the transcript. That is exactly
how the first two Lorenz seeds were lost.
"""
function run_turn!(server, project, prompt; timeout = 3600)
    model = BT.ensure_project_session!(server.h.state, project)
    sh = BT.shared(model)
    BT.send_message!(model, BT.UserMsg(model, prompt))
    t0 = time()
    while !sh.busy_active[] && time() - t0 < 120; sleep(2); end
    last_report = time()
    while sh.busy_active[] && time() - t0 < timeout
        sleep(5)
        if time() - last_report > 60
            @info "seed: still working" chat = project.name minutes = round((time() - t0) / 60, digits = 1) messages = length(sh.msgs_store)
            last_report = time()
        end
    end
    sh.busy_active[] && @warn "seed: turn STILL busy at the budget — the rig is about to " *
                              "close and will kill it; raise the timeout" name = project.name
    sleep(5)   # let the last frames persist before anything tears down
    return model
end

# `BT_WALKTHROUGH_SEED_DRY=1` lays out the projects and registers them but sends
# no prompt — the plumbing check that costs nothing.
const DRY = get(ENV, "BT_WALKTHROUGH_SEED_DRY", "") == "1"

function seed!(server, s::Seed)
    @info "seeding" chat = s.name dry = DRY
    dir = lay_out!(server, s)
    project = register!(server, s, dir)
    DRY && (@info "dry run: project registered, no prompt sent" chat = s.name dir = dir; return true)
    model = run_turn!(server, project, s.prompt)
    msgs = BT.shared(model).msgs_store
    ok = s.verify(msgs)
    @info "seeded" chat = s.name messages = length(msgs) usable_on_camera = ok
    ok || @warn "seed produced nothing the tour can film — re-run this one seed" chat = s.name
    return ok
end

"""
Fail BEFORE any tokens are spent if the demo eval env can't load what the prompts
ask the agent to use. The first seeding attempt lost a full Opus turn to an env
whose Reseau (≤1.3.4, expired precompile certificate) could not precompile: the
agent spent the turn debugging the env instead of building the app, and the
transcript was unusable.
"""
function check_eval_env()
    @info "checking the demo eval env loads" env = SEED_EVAL_ENV
    ok = success(pipeline(`$(Base.julia_cmd()) --project=$(SEED_EVAL_ENV) --startup-file=no
                           -e "using Bonito, WGLMakie"`; stdout = devnull, stderr = devnull))
    ok || error("seed: $(SEED_EVAL_ENV) cannot load Bonito + WGLMakie — fix the env " *
                "first (`Pkg.update()` there), or point BT_WALKTHROUGH_EVAL_ENV elsewhere. " *
                "Seeding into a broken env burns a turn on the agent debugging it.")
    return nothing
end

function main(names = String[])
    wanted = isempty(names) ? SEEDS : filter(s -> s.name in names, SEEDS)
    isempty(wanted) && error("no seed matches $(names); known: $(join([s.name for s in SEEDS], ", "))")
    DRY || check_eval_env()
    server = attach_rig()
    try
        # The rig worker dials back asynchronously; a prompt before its control
        # WS is up dies in the lazy ACP bind.
        t0 = time()
        while isempty(server.h.state.worker_control_ws) && time() - t0 < 60; sleep(0.5); end
        isempty(server.h.state.worker_control_ws) && error("seed: rig worker never connected")
        results = [(s.name, seed!(server, s)) for s in wanted]
        @info "seeding done" results
    finally
        close(server)
    end
    return 0
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
