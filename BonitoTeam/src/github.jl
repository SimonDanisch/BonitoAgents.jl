# "Open from GitHub" project flow.
#
# Takes any one of:
#
#   https://github.com/<owner>/<repo>            (or .git, trailing slash)
#   https://github.com/<owner>/<repo>/issues/<n>
#   https://github.com/<owner>/<repo>/pull/<n>
#
# and produces a project on the configured worker:
#   1. Clones the repo into <projects_root>/<derived-name> on the worker.
#   2. For PRs: also fetches and checks out the PR head ref.
#   3. For issues/PRs: fetches title+body via the GitHub REST API and stores
#      it as the project's `auto_prompt` so the first chat message is the
#      "fix this" prompt.

struct GithubRef
    owner   :: String
    repo    :: String
    kind    :: Symbol            # :repo, :issue, :pull
    number  :: Union{Int,Nothing}
end

# https://github.com/<owner>/<repo>(.git)?(/issues/<n>|/pull/<n>)?(/?)
const GITHUB_URL_RX = r"""^https?://github\.com/
                          (?<owner>[A-Za-z0-9_.\-]+)/
                          (?<repo>[A-Za-z0-9_.\-]+?)
                          (?:\.git)?
                          (?:/(?<kind>issues|pull)/(?<num>\d+))?
                          /?$"""x

"""
    parse_github_url(url) → GithubRef

Throws if `url` isn't a github.com URL pointing at a repo, issue, or PR.
"""
function parse_github_url(url::AbstractString)
    m = match(GITHUB_URL_RX, strip(url))
    m === nothing && error("Not a recognised GitHub URL: $url")
    kind = m[:kind] === nothing ? :repo :
           m[:kind] == "pull"  ? :pull : :issue
    num  = m[:num] === nothing ? nothing : parse(Int, m[:num])
    return GithubRef(String(m[:owner]), String(m[:repo]), kind, num)
end

# Server-side fetch of issue/PR metadata. Uses the unauthenticated REST API
# unless GITHUB_TOKEN is set in the env (for higher rate limit + private
# repos). Returns (title, body) or throws.
function fetch_github_issue(owner::AbstractString, repo::AbstractString,
                              number::Integer)
    api_url = "https://api.github.com/repos/$owner/$repo/issues/$number"
    headers = Pair{String,String}["Accept" => "application/vnd.github+json",
                                   "User-Agent" => "BonitoTeam"]
    tok = get(ENV, "GITHUB_TOKEN", "")
    isempty(tok) || push!(headers, "Authorization" => "Bearer $tok")
    resp = HTTP.get(api_url, headers; status_exception = true, retry = false,
                     readtimeout = 15)
    payload = JSON.parse(String(resp.body))
    return (title = String(payload["title"]),
            body  = String(something(payload["body"], "")))
end

# Build the human-readable initial prompt from issue/PR metadata.
function github_issue_prompt(ref::GithubRef, title::AbstractString,
                              body::AbstractString)
    kind_word = ref.kind == :pull ? "pull request" : "issue"
    verb      = ref.kind == :pull ?
                "Please review and complete this pull request" :
                "Please look into this issue and propose a fix"
    return string(verb, " (", ref.owner, "/", ref.repo, " #", ref.number,
                  ").\n\n# ", title, "\n\n",
                  isempty(body) ? "(no $kind_word body)" : body)
end

# Derive a filesystem-safe project name. Issues/PRs include the number so
# multiple slices of the same repo don't collide on disk.
function github_project_name(ref::GithubRef)
    base = replace(ref.repo, r"[^A-Za-z0-9_\-]" => "-")
    if ref.kind == :issue
        return "$(base)-issue-$(ref.number)"
    elseif ref.kind == :pull
        return "$(base)-pr-$(ref.number)"
    else
        return base
    end
end

"""
    create_project_from_github!(state, url; worker_name, name=nothing,
                                  progress = nothing) → ProjectInfo

End-to-end "From GitHub" creation. Clones the repo on the worker, sets up
the auto-prompt for issues/PRs, and registers the project so the chat is
immediately reachable at `/p/<id>`.
"""
function create_project_from_github!(state::ServerState, url::AbstractString;
                                       worker_name::AbstractString,
                                       name::Union{String,Nothing} = nothing,
                                       agent_type::AbstractString = "claude",
                                       progress = nothing)
    haskey(state.workers[], worker_name) || error("Unknown worker: $worker_name")
    ref = parse_github_url(url)
    proj_name = something(name, github_project_name(ref))
    occursin(r"^[a-zA-Z0-9_\-]+$", proj_name) ||
        error("Derived project name '$proj_name' is invalid; pass `name=` explicitly")

    w = state.workers[][worker_name]
    server_path = joinpath(state.working_dir, proj_name)
    worker_path = joinpath(w.projects_root, proj_name)

    # Idempotent re-clone: a project at the same `(worker, worker_path)` is
    # treated as the canonical one; we don't reclone, but we do refresh the
    # auto_prompt for issue/PR URLs since the operator likely wants the new
    # task seeded into the chat.
    existing = find_project_by_location(state, worker_name, worker_path)
    if existing !== nothing
        @info "create_project_from_github!: reusing existing project" id=existing.id name=existing.name
        if ref.kind != :repo
            notify_progress(progress, :phase, (msg = "Fetching $(ref.kind) #$(ref.number) metadata…",))
            meta = fetch_github_issue(ref.owner, ref.repo, ref.number)
            existing.auto_prompt = github_issue_prompt(ref, meta.title, meta.body)
            save_projects!(state)
        end
        ensure_project_session!(state, existing)
        return existing
    end

    id          = string(uuid4())[1:8]
    clone_url   = "https://github.com/$(ref.owner)/$(ref.repo).git"
    pr_number   = ref.kind == :pull ? ref.number : nothing

    notify_progress(progress, :phase, (msg = "Cloning $(ref.owner)/$(ref.repo) on worker…",))
    clone_repo_on_worker(state, worker_name, clone_url, worker_path; pr_number = pr_number)

    auto_prompt = if ref.kind == :repo
        nothing
    else
        notify_progress(progress, :phase, (msg = "Fetching $(ref.kind) #$(ref.number) metadata…",))
        meta = fetch_github_issue(ref.owner, ref.repo, ref.number)
        github_issue_prompt(ref, meta.title, meta.body)
    end

    p = ProjectInfo(id, proj_name, worker_name, server_path, worker_path, now(UTC))
    p.auto_prompt = auto_prompt
    p.agent_type  = String(agent_type)
    lock(state.lock) do
        state.projects[][id] = p
        save_projects!(state)
    end
    safe_notify!(state.projects)

    notify_progress(progress, :phase, (msg = "Starting chat session…",))
    ensure_project_session!(state, p)
    return p
end
