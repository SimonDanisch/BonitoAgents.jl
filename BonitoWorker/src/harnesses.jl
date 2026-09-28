# ── Managed agent adapters ───────────────────────────────────────────────────
# The ACP adapters (claude-agent-acp, codex-acp) are npm packages that move fast.
# Instead of each machine's owner updating global npm installs by hand (often
# with sudo), the worker owns them: it keeps a private Node and installs the
# adapters into its own prefix, at the versions the server declares
# (`HarnessSpec`, sent with the hello acknowledgement). A chat then runs the
# managed adapter; an explicit override (`CLAUDE_AGENT_ACP`, …) still wins, and a
# provider without a managed install runs whatever PATH has.
#
# Updates happen while the worker is idle: a running agent never has its files
# replaced underneath it. Login stays the user's (`~/.claude`, `~/.codex`); the
# managed adapters read it like the global ones did.
#
# Layout under `harness_root()`:
#   node-v<version>-<os>-<arch>/   a Node release, unpacked as published
#   node-version                   which of those is current
#   npm/node_modules/…             the adapters (`npm install --prefix npm`)

const NODE_DIST = "https://nodejs.org/dist"

# What the server wants installed: Node as `"lts"`, a major (`"22"`) or an exact
# version, and each npm package as `"latest"` or an exact version.
struct HarnessSpec
    node::String
    packages::Dict{String,String}
end

function harness_spec_from_wire(x)
    x isa AbstractDict || return nothing
    node = get(x, "node", nothing)
    pkgs = get(x, "packages", nothing)
    (node isa AbstractString && !isempty(node) && pkgs isa AbstractDict) || return nothing
    packages = Dict{String,String}()
    for (k, v) in pkgs
        v isa AbstractString && !isempty(v) || return nothing
        packages[String(k)] = String(v)
    end
    return HarnessSpec(String(node), packages)
end

harness_root() = joinpath(config_dir(), "harnesses")

# The Node release to install for `want`, from nodejs.org's release index
# (newest first).
function resolve_node_version(want::AbstractString; index = node_index())
    version(entry) = lstrip(String(entry["version"]), 'v')
    if want == "lts"
        entry = findfirst(e -> e["lts"] !== false, index)
        entry === nothing && error("nodejs.org lists no LTS release")
        return version(index[entry])
    elseif occursin(r"^\d+$", want)
        entry = findfirst(e -> startswith(String(e["version"]), "v$(want)."), index)
        entry === nothing && error("nodejs.org lists no Node $(want) release")
        return version(index[entry])
    end
    return String(lstrip(want, 'v'))
end

node_index() = JSON.parse(String(HTTP.get("$(NODE_DIST)/index.json").body))

# The published archive for this machine: its directory name and extension.
function node_asset(version::AbstractString)
    arch = Sys.ARCH === :x86_64 ? "x64" : Sys.ARCH === :aarch64 ? "arm64" :
           error("no Node build for $(Sys.ARCH)")
    os = Sys.iswindows() ? "win" : Sys.isapple() ? "darwin" : Sys.islinux() ? "linux" :
         error("no Node build for this operating system")
    return (name = "node-v$(version)-$(os)-$(arch)", ext = Sys.iswindows() ? "zip" : "tar.gz")
end

# Where a Node release keeps `node` and `npm`.
node_bin_dir(nodedir::AbstractString) = Sys.iswindows() ? nodedir : joinpath(nodedir, "bin")

function current_node_dir(root::AbstractString = harness_root())
    f = joinpath(root, "node-version")
    isfile(f) || return nothing
    dir = joinpath(root, node_asset(strip(read(f, String))).name)
    return isdir(dir) ? dir : nothing
end

# SHA-256 of a file, through the system's own tool: BonitoWorker carries no
# hashing library, and every platform a worker runs on has one of these.
function file_sha256(path::AbstractString)
    out = Sys.iswindows() ? read(`certutil -hashfile $path SHA256`, String) :
          Sys.isapple()   ? read(`shasum -a 256 $path`, String) :
                            read(`sha256sum $path`, String)
    for line in split(out, '\n')
        m = match(r"^([0-9a-fA-F]{64})\b", replace(strip(line), " " => ""))
        m === nothing || return lowercase(m[1])
    end
    error("could not read a SHA-256 from: $(out)")
end

# Download, verify against the release's SHASUMS256.txt, and unpack one Node
# release into `root`. Returns its directory.
function install_node!(root::AbstractString, version::AbstractString)
    asset = node_asset(version)
    dest = joinpath(root, asset.name)
    if !isdir(dest)
        file = "$(asset.name).$(asset.ext)"
        sums = String(HTTP.get("$(NODE_DIST)/v$(version)/SHASUMS256.txt").body)
        m = match(Regex("^([0-9a-f]{64})\\s+\\Q$(file)\\E\$", "m"), sums)
        m === nothing && error("Node $(version) publishes no checksum for $(file)")
        archive = joinpath(root, file)
        write(archive, HTTP.get("$(NODE_DIST)/v$(version)/$(file)").body)
        try
            got = file_sha256(archive)
            got == m[1] || error("checksum mismatch for $(file): expected $(m[1]), got $(got)")
            run(`tar -xf $archive -C $root`)
        finally
            rm(archive; force = true)
        end
        isdir(dest) || error("unpacking $(file) did not produce $(dest)")
    end
    write(joinpath(root, "node-version"), version)
    # Only the current release is kept (not the `node-version` marker beside it).
    for entry in readdir(root)
        occursin(r"^node-v\d", entry) && entry != asset.name &&
            rm(joinpath(root, entry); recursive = true, force = true)
    end
    return dest
end

# `npm` from the private Node, with that Node first on PATH (npm is a node
# script) and none of the worker's credentials in its environment.
function npm_cmd(nodedir::AbstractString, args::Cmd)
    bindir = node_bin_dir(nodedir)
    exe = joinpath(bindir, Sys.iswindows() ? "npm.cmd" : "npm")
    env = inherited_env()
    env["PATH"] = bindir * (Sys.iswindows() ? ';' : ':') * get(env, "PATH", "")
    env["npm_config_update_notifier"] = "false"
    env["npm_config_fund"] = "false"
    env["npm_config_audit"] = "false"
    return setenv(`$exe $args`, env)
end

function package_dir(root::AbstractString, pkg::AbstractString)
    return joinpath(root, "npm", "node_modules", split(pkg, '/')...)
end

function installed_version(root::AbstractString, pkg::AbstractString)
    f = joinpath(package_dir(root, pkg), "package.json")
    isfile(f) || return nothing
    return String(JSON.parsefile(f)["version"])
end

"What is installed under `root`: Node and each of `packages`, by version."
function installed_harnesses(root::AbstractString, packages)
    out = Dict{String,String}()
    f = joinpath(root, "node-version")
    isfile(f) && (out["node"] = strip(read(f, String)))
    for pkg in packages
        v = installed_version(root, pkg)
        v === nothing || (out[pkg] = v)
    end
    return out
end

"""
    sync_harnesses!(spec; root = harness_root(), log = devnull) -> Dict{String,String}

Bring `root` to what `spec` asks for: the Node release it names, and each package
at its version (`"latest"` is resolved against the registry every time). Returns
what is installed afterwards. Idempotent: what is already current is skipped.
"""
function sync_harnesses!(spec::HarnessSpec; root::AbstractString = harness_root(),
                         log = devnull)
    mkpath(root)
    nodedir = install_node!(root, resolve_node_version(spec.node))
    prefix = mkpath(joinpath(root, "npm"))
    for (pkg, want) in spec.packages
        target = want == "latest" ?
            strip(read(npm_cmd(nodedir, `view $pkg version`), String)) : want
        installed_version(root, pkg) == target && continue
        @info "BonitoWorker: installing agent adapter" package = pkg version = target
        run(pipeline(npm_cmd(nodedir, `install --prefix $prefix $pkg@$target`);
                     stdout = log, stderr = log))
    end
    return installed_harnesses(root, keys(spec.packages))
end

"""
    managed_agent(provider; root = harness_root()) -> (bin, path) or nothing

The worker's own install of `provider`'s adapter, with the directory its Node
lives in (the adapter is a node script, so that goes first on PATH); `nothing`
when the provider is not managed or not installed here.
"""
function managed_agent(provider; root::AbstractString = harness_root())
    AgentProviders.npm_package(provider) === nothing && return nothing
    nodedir = current_node_dir(root)
    nodedir === nothing && return nothing
    bin = joinpath(root, "npm", "node_modules", ".bin",
                   AgentProviders.npm_bin(provider) * (Sys.iswindows() ? ".cmd" : ""))
    isfile(bin) || return nothing
    return (bin = bin, path = node_bin_dir(nodedir))
end

"""
    agent_command(provider) -> (bin, path)

What runs a chat's agent: an explicit override wins, then the worker's managed
adapter, then whatever PATH resolved when the descriptor was built. `path` is a
directory to put first on the agent's PATH, or `""`.
"""
function agent_command(provider)
    override = AgentProviders.bin_override(provider)
    isempty(override) || return (bin = override, path = "")
    managed = managed_agent(provider)
    managed === nothing || return managed
    return (bin = provider.bin, path = "")
end
