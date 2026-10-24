@testitem "unit:render_collections" tags = [:unit] begin
    using Test, BonitoAgents
    const BT = BonitoAgents

    @testset "DOM children stay collections instead of input-sized argument tuples" begin
        function splats!(found, ex, line = Ref(1))
            if ex isa LineNumberNode
                line[] = ex.line
            elseif ex isa Expr
                if ex.head == :call && ex.args[1] isa Expr &&
                   ex.args[1].head == :. && ex.args[1].args[1] == :DOM
                    for arg in ex.args[2:end]
                        arg isa Expr && arg.head == :... &&
                            push!(found, (line[], string(ex.args[1]), string(arg)))
                    end
                end
                foreach(arg -> splats!(found, arg, line), ex.args)
            end
            return found
        end
        for (root, _, files) in walkdir(joinpath(pkgdir(BT), "src")), file in files
            endswith(file, ".jl") || continue
            path = joinpath(root, file)
            @testset "$file" begin
                @test isempty(splats!(Any[], Meta.parseall(read(path, String))))
            end
        end
    end

    @testset "new search result counts do not trigger seconds of compilation" begin
        BT.render_search_results("warmup.jl:1:warmup")
        for n in (173, 229, 317)
            source = join(("src/file$i.jl:$i:match_$i" for i in 1:n), '\n')
            elapsed = @elapsed dom = BT.render_search_results(source)
            @test elapsed < 1.0
            html = repr(MIME"text/html"(), dom)
            @test count("class=\"bt-search-row\"", html) == n
            @test occursin("data-path=\"src/file$n.jl\"", html)
            @test occursin("match_$n", html)
        end
    end
end
