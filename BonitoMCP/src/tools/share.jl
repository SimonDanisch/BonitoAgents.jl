# bt_share: a link to a file on this worker, for anyone (BonitoAgents' shares.jl
# does the work; this only asks the server).

# An app link evaluates the file once before it is handed out: the first time on
# a worker that starts Julia there, then the app's packages.
const SHARE_TOOL_TIMEOUT_S = 900.0

function share_handler(args::AbstractDict)
    path = String(strip(String(get(args, "path", ""))))
    isempty(path) && return tool_error("`path` (the file to share) is required")
    reply = try
        call_server("share"; timeout = SHARE_TOOL_TIMEOUT_S, path,
                    title = String(get(args, "title", "")),
                    password = String(get(args, "password", "")),
                    env_path = String(get(args, "env_path", "")))
    catch e
        e isa InterruptException && rethrow()
        return tool_error(sprint(showerror, e))
    end
    reply isa AbstractDict || return tool_error("unexpected reply from the server: $(repr(reply))")
    env = String(get(reply, "env_path", ""))
    text = "shared $(get(reply, "path", path)) as a $(get(reply, "kind", "page")): $(get(reply, "url", "?"))" *
           (get(reply, "password", false) === true ? "\n(protected by the password given)" : "") *
           (get(reply, "kind", "") == "app" ? "\nruns in " * (isempty(env) ? "a temporary environment" : env) : "")
    return Dict{String,Any}("content" => [Dict("type" => "text", "text" => text)], "isError" => false)
end

register!(
    "bt_share",
    """
    Share a file on this worker as a link anyone can open (no account needed),
    for as long as this worker is online. Give the link to the user.
      - A markdown file (.md) becomes a page; the images and videos it embeds by
        relative path (`![plot](figs/plot.png)`, `![](clip.mp4)`, a `<video>`)
        come along. Nothing else in its folder is reachable through the link.
      - A Julia file (.jl) whose last value is a Bonito `App` (or anything
        bt_julia_eval would show live: a plot, a DataFrame) becomes a live page.
        It runs in `env_path` (default: the nearest folder above the file with a
        Project.toml), and is evaluated again when the file changes. Interactive
        markdown is an app (a plain Julia file: it loads what it uses):
          using Bonito, Markdown
          App() do
              s = Bonito.Slider(1:10)
              DOM.div(md\"\"\"
              # Report
              Pick a value: \$(s) → \$(map(x -> x^2, s.value))
              \"\"\")
          end
        The file is evaluated once now, so an error in it comes back here.
      - Other files are served directly, including images, videos and documents.
        Only that file is reachable. HTML and SVG are sandboxed without scripts.
    The chat's Share button can also share a live bt_julia_eval result without
    evaluating its code again; that link needs the original Julia session and
    result to stay open.
    The user sees, changes the password of, and ends links in Settings.
    """,
    Dict{String,Any}(
        "type" => "object",
        "properties" => Dict{String,Any}(
            "path"     => Dict("type"=>"string", "description"=>"The file to share (absolute, or relative to the project folder)"),
            "title"    => Dict("type"=>"string", "description"=>"The page title; default: the file name"),
            "password" => Dict("type"=>"string", "description"=>"Optional: viewers must enter it first"),
            "env_path" => Dict("type"=>"string", "description"=>"Julia files only: the project the app runs in"),
        ),
        "required" => ["path"],
    ),
    share_handler,
)
