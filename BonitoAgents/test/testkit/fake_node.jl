# A stand-in for nodejs.org/dist and the npm registry, for the worker's managed
# agent adapters (BonitoWorker's harnesses.jl). The worker gets it through
# `BONITOAGENTS_NODE_DIST`, exactly as it would a mirror: an `index.json`, and per
# release a `SHASUMS256.txt` and the archive for this machine, with real
# checksums. What the archives hold is not Node: their `npm` answers the two
# commands the worker runs, `npm view <pkg> version` and
# `npm install --prefix <dir> <pkg>@<version>`, from a directory of "published"
# versions (`publish!`), and records each install (`installs`). An installed
# adapter is a script that prints its package and version.
#
# Included into TestKit and into unit items that need it (it needs `HTTP`, `SHA`,
# `JSON` and `BonitoWorker` in scope).

struct FakeNodeDist
    server::HTTP.Server
    url::String
    dir::String        # what the server serves: the `dist` tree
    registry::String   # `BT_FAKE_NPM_REGISTRY`: published versions and installs.log
end

const FAKE_NPM = raw"""
#!/bin/sh
# npm, as far as BonitoWorker's harnesses.jl uses it.
reg="$BT_FAKE_NPM_REGISTRY"
key() { printf '%s' "$1" | tr '/@' '__'; }
case "$1" in
    view)
        [ -f "$reg/$(key "$2")" ] || { echo "npm ERR! 404 '$2' is not in this registry" >&2; exit 1; }
        cat "$reg/$(key "$2")" ;;
    install)
        prefix="$3"; spec="$4"; pkg="${spec%@*}"; ver="${spec##*@}"
        mkdir -p "$prefix/node_modules/$pkg" "$prefix/node_modules/.bin"
        printf '{"name": "%s", "version": "%s"}\n' "$pkg" "$ver" > "$prefix/node_modules/$pkg/package.json"
        bin="$prefix/node_modules/.bin/${pkg##*/}"
        printf '#!/bin/sh\necho "%s %s"\n' "$pkg" "$ver" > "$bin"
        chmod +x "$bin"
        echo "$spec" >> "$reg/installs.log"
        echo "$npm_config_cache" > "$reg/cache.log" ;;
    *) echo "fake npm: unsupported: $*" >&2; exit 1 ;;
esac
"""

"""
    fake_node_dist(; releases, published) -> FakeNodeDist

Serve Node `releases` (newest first; `version => lts`, where `lts` is a codename
or `false`) on a local port, with `published` (package => latest version) in its
registry. Set `ENV["BT_FAKE_NPM_REGISTRY"] = dist.registry` for the process that
runs npm.
"""
function fake_node_dist(; releases = ["25.1.0" => false, "24.9.0" => "Krypton", "22.20.0" => "Jod"],
                          published = Dict{String,String}())
    dir = mktempdir()
    registry = mktempdir()
    write(joinpath(dir, "index.json"),
          JSON.json([Dict("version" => "v$(v)", "lts" => lts) for (v, lts) in releases]))
    for (version, _) in releases
        asset = BonitoWorker.node_asset(version)
        stage = mktempdir()
        bin = mkpath(joinpath(stage, asset.name, "bin"))
        write(joinpath(bin, "npm"), FAKE_NPM)
        write(joinpath(bin, "node"), "#!/bin/sh\necho v$(version)\n")
        chmod(joinpath(bin, "npm"), 0o755); chmod(joinpath(bin, "node"), 0o755)
        release = mkpath(joinpath(dir, "v$(version)"))
        file = "$(asset.name).$(asset.ext)"
        run(`tar -czf $(joinpath(release, file)) -C $(stage) $(asset.name)`)
        rm(stage; recursive = true)
        write(joinpath(release, "SHASUMS256.txt"),
              "$(bytes2hex(SHA.sha256(read(joinpath(release, file)))))  $(file)\n")
    end
    server = HTTP.serve!("127.0.0.1", 0; verbose = false) do request
        path = joinpath(dir, split(HTTP.URI(request.target).path, '/'; keepempty = false)...)
        isfile(path) ? HTTP.Response(200, read(path)) : HTTP.Response(404, "not in this mirror")
    end
    dist = FakeNodeDist(server, "http://127.0.0.1:$(HTTP.port(server))", dir, registry)
    for (pkg, version) in published
        publish!(dist, pkg, version)
    end
    return dist
end

"Make `version` the one `npm view <pkg> version` answers."
publish!(dist::FakeNodeDist, pkg::AbstractString, version::AbstractString) =
    write(joinpath(dist.registry, replace(pkg, '/' => '_', '@' => '_')), version * "\n")

"Every `pkg@version` npm installed so far, in order."
installs(dist::FakeNodeDist) =
    isfile(joinpath(dist.registry, "installs.log")) ? readlines(joinpath(dist.registry, "installs.log")) : String[]

"Break a release's published checksum, as a corrupted or tampered download would."
function corrupt_checksum!(dist::FakeNodeDist, version::AbstractString)
    f = joinpath(dist.dir, "v$(version)", "SHASUMS256.txt")
    write(f, replace(read(f, String), r"^[0-9a-f]{64}" => "0"^64))
    return nothing
end

Base.close(dist::FakeNodeDist) = close(dist.server)
