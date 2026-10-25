# Linux backend. Two interchangeable tools:
#   :bwrap   — bubblewrap, a namespaces-based sandbox (default when present).
#   :landrun — Landlock LSM wrapper.
# Both implement the shared contract: build_jail_cmd(exe, wl, ro, cfg) -> Cmd.

default_backend() = Sys.which("bwrap") !== nothing ? :bwrap : :landrun

"True when running inside WSL2 (GPU is exposed via /dev/dxg, not /dev/dri+kfd)."
function is_wsl()
    isfile("/proc/version") || return false
    return occursin("microsoft", lowercase(read("/proc/version", String)))
end

"Best-effort list of GPU device nodes to expose, based on what actually exists."
function gpu_device_nodes()
    nodes = String[]
    if is_wsl()
        ispath("/dev/dxg") && push!(nodes, "/dev/dxg")            # WSL2 paravirtual GPU
    else
        ispath("/dev/dri") && push!(nodes, "/dev/dri")            # DRM / Vulkan (AMD, Intel, NV)
        ispath("/dev/kfd") && push!(nodes, "/dev/kfd")            # ROCm compute (AMD)
        for n in ("/dev/nvidia0", "/dev/nvidiactl", "/dev/nvidia-uvm",
                  "/dev/nvidia-uvm-tools", "/dev/nvidia-modeset")
            ispath(n) && push!(nodes, n)
        end
    end
    return nodes
end

"Read-only paths the GPU userspace driver needs (WSL ships its libs here)."
function gpu_support_paths()
    paths = String[]
    is_wsl() && isdir("/usr/lib/wsl") && push!(paths, "/usr/lib/wsl")
    return paths
end

function build_jail_cmd(exe::Vector{String}, whitelist::Vector{String},
                        readonly::Vector{String}, cfg::JailConfig)
    if cfg.backend === :bwrap
        return _build_bwrap(exe, whitelist, readonly, cfg)
    elseif cfg.backend === :landrun
        return _build_landrun(exe, whitelist, readonly, cfg)
    else
        error("Jail: unknown Linux backend $(cfg.backend) (use :bwrap or :landrun)")
    end
end

function _build_bwrap(exe, whitelist, readonly, cfg::JailConfig)
    bwrap = Sys.which("bwrap")
    bwrap === nothing && error("Jail: `bwrap` not found. Install bubblewrap or pass backend=:landrun.")

    a = String[bwrap, "--die-with-parent", "--new-session", "--unshare-pid", "--proc", "/proc"]

    for d in cfg.system_ro
        append!(a, ["--ro-bind-try", d, d])
    end

    # Build /dev first, THEN add GPU nodes: device binds after `--dev /dev`,
    # otherwise the fresh devtmpfs shadows them (containers/bubblewrap#248).
    append!(a, ["--dev", "/dev"])
    if cfg.gpu
        for n in gpu_device_nodes()
            append!(a, ["--dev-bind-try", n, n])
        end
        for p in gpu_support_paths()
            append!(a, ["--ro-bind-try", p, p])
        end
    end

    append!(a, ["--tmpfs", "/tmp"])

    for d in whitelist
        # A whitelist dir that doesn't exist yet must NOT abort the whole launch
        # (R6): `--bind` errors hard if the source is missing. Create it (the
        # whitelist is read-write, so the caller intends to use it) and bind it;
        # if creation fails (e.g. a parent we can't write), fall back to
        # `--bind-try` so bwrap skips it gracefully instead of dying.
        if isdir(d)
            append!(a, ["--bind", d, d])        # read-write
        else
            made = try
                mkpath(d); true
            catch e
                @warn "Jail: could not create whitelist dir; binding best-effort" dir=d exception=e
                false
            end
            append!(a, [made ? "--bind" : "--bind-try", d, d])
        end
    end
    for d in readonly
        append!(a, ["--ro-bind-try", d, d]) # read-only
    end

    cfg.network || push!(a, "--unshare-net")
    isempty(whitelist) || append!(a, ["--chdir", first(whitelist)])

    append!(a, exe)
    return Cmd(a)
end

function _build_landrun(exe, whitelist, readonly, cfg::JailConfig)
    landrun = Sys.which("landrun")
    landrun === nothing && error("Jail: `landrun` not found. Install it or pass backend=:bwrap.")

    # --ldd / --add-exec auto-grant the binary + its shared libs.
    # --best-effort degrades gracefully and covers Landlock ioctl gating on
    # kernels >= 6.10 (ABI v5), which can otherwise block GPU ioctls.
    a = String[landrun, "--best-effort", "--add-exec", "--ldd"]

    for d in cfg.system_ro
        isdir(d) && append!(a, ["--rox", d])
    end
    if cfg.gpu
        for n in gpu_device_nodes()
            append!(a, ["--rw", n])
        end
        for p in gpu_support_paths()
            append!(a, ["--rox", p])
        end
    end

    for d in whitelist
        append!(a, ["--rw", d])
    end
    for d in readonly
        append!(a, ["--ro", d])
    end

    cfg.network && push!(a, "--unrestricted-network")
    for e in cfg.env
        append!(a, ["--env", e])
    end

    append!(a, exe)
    return Cmd(a)
end
