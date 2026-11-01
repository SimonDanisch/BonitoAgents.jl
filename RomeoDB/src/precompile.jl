# Every tool, once, through the server's loop over a one-package index: a fresh server
# then answers its first queries without compiling them (seconds otherwise).
PrecompileTools.@setup_workload begin
    code = """
        \"\"\"
            sumsq(xs)

        Sum of the squares of `xs`.
        \"\"\"
        function sumsq(xs::AbstractVector{T}) where {T}
            acc = zero(T)
            for x in xs
                acc += x * x
            end
            return acc
        end
        """
    calls = [("search", Dict("query" => "sum of squares", "gpu" => true)),
             ("search", Dict("query" => "sumsq", "alternatives" => ["squared norm"])),
             ("search_packages", Dict("query" => "squares")),
             ("search_packages", Dict("query" => "sum of squares", "alternatives" => ["squared norm"])),
             ("similar_code", Dict("code" => code)),
             ("find_existing", Dict("code" => code, "purpose" => "sum of squares")),
             ("definition", Dict("package" => "Example", "name" => "sumsq")),
             ("implementers", Dict("function" => "Base.sum")),
             ("package_info", Dict("package" => "Example")),
             ("dependents", Dict("package" => "Example"))]
    PrecompileTools.@compile_workload begin
        dir = mktempdir()
        idx = Index(joinpath(dir, "index"))
        p = PackageVersion(UUID(1), "Example", v"1.0.0", SHA1(zeros(UInt8, 20)), "")
        root = mkpath(joinpath(sourcedir(idx, p), "src"))
        write(joinpath(root, "Example.jl"), "module Example\nexport sumsq\n$code\nend\n")
        store!(idx, p, "ok", extract(dirname(root), "Example"))
        reindex_text!(idx)
        mine = mkpath(joinpath(dir, "Mine", "src"))
        write(joinpath(mine, "Mine.jl"), "module Mine\n$code\nend\n")
        push!(calls, ("audit_package", Dict("path" => dirname(mine))))
        msgs = [Dict("jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => Dict()),
                Dict("jsonrpc" => "2.0", "id" => 2, "method" => "tools/list")]
        for (i, (name, args)) in enumerate(calls)
            push!(msgs, Dict("jsonrpc" => "2.0", "id" => 2 + i, "method" => "tools/call",
                             "params" => Dict("name" => name, "arguments" => args)))
        end
        serve(idx.dir; input = IOBuffer(join(JSON3.write.(msgs), "\n")), output = IOBuffer())
        DBInterface.close!(idx.db)
    end
end
