# How well definition search answers a need put in words, on a built index: for each
# query, packages whose functions an expert would call. Run after changing the ranking:
#
#     using RomeoDB; include("eval/definition_search.jl"); evaluate_definitions(RomeoDB.Index("/path/to/data"))
#
# Scored on 2026-10-28: MRR 0.68, a judged package's definition in the top 5 for 17 of
# 20 queries, 0.3 s a query. Without the definitions of the best matching packages fused
# in (`topical`) it was 0.388 and 12/20. With the package vectors choosing those
# packages too (`semantic`, see eval/package_search.jl): 0.704, 17/20.

using RomeoDB

const DEFJUDGED = [
    "smooth a noisy signal" => ["DSP", "Loess", "SmoothingSplines", "SavitzkyGolay", "ImageFiltering", "KernelDensity"],
    "find peaks in a signal" => ["Peaks", "Findpeaks", "DSP"],
    "distance between two points on earth" => ["Distances", "Geodesy", "Proj", "GeoFormatTypes", "GeometryOps"],
    "check if point is inside polygon" => ["PolygonOps", "GeometricalPredicates", "GeometryOps", "Meshes", "LibGEOS",
                                           "PolygonAlgorithms"],
    "convex hull of points" => ["DelaunayTriangulation", "QHull", "LazySets", "Polyhedra", "MiniQhull", "Meshes",
                                "PolygonAlgorithms"],
    "resize an image" => ["ImageTransformations", "Images", "Augmentor"],
    "parse command line arguments" => ["ArgParse", "Comonicon", "DocOpt", "SimpleArgParse"],
    "run function in parallel threads" => ["OhMyThreads", "FLoops", "ThreadsX", "Polyester", "ChunkSplitters", "Transducers"],
    "pretty print a table" => ["PrettyTables", "DataFrames"],
    "progress bar" => ["ProgressMeter", "ProgressBars", "ProgressLogging", "Term"],
    "solve linear system sparse" => ["LinearSolve", "Krylov", "KLU", "Pardiso", "IterativeSolvers", "Sparspak", "SparseArrays"],
    "random numbers with seed" => ["StableRNGs", "RandomNumbers", "Random123"],
    "cache function results" => ["Memoize", "Memoization", "LRUCache", "Caching"],
    "read a json file" => ["JSON", "JSON3"],
    "send an http request" => ["HTTP", "Downloads"],
    "fit a curve to data" => ["LsqFit", "CurveFit", "Polynomials", "GLM"],
    "moving average" => ["RollingFunctions", "MarketTechnicals", "DSP", "TimeSeries"],
    "root finding" => ["Roots", "NonlinearSolve", "NLsolve"],
    "numerical integration of a function" => ["QuadGK", "Integrals", "HCubature", "Cubature"],
    "nearest neighbor search" => ["NearestNeighbors", "CellListMap", "HNSW"],
]

"""
    evaluate_definitions(idx; show = false, semantic = nothing) -> (mrr, hit5)

Mean reciprocal rank of the first hit from a judged package, and how many queries have
one in the top 5. With `show`, each query's rank and the packages of its top 5 hits.
"""
function evaluate_definitions(idx::RomeoDB.Index; show::Bool = false, semantic = nothing)
    mrr, hit = 0.0, 0
    for (q, judged) in DEFJUDGED
        packages = [h.package for h in RomeoDB.search(idx, q; limit = 20, semantic)]
        i = findfirst(in(judged), packages)
        mrr += i === nothing ? 0.0 : 1 / i
        hit += i !== nothing && i <= 5
        show && println(rpad(q, 38), rpad(something(i, "-"), 4), join(packages[1:min(end, 5)], ", "))
    end
    return (mrr = round(mrr / length(DEFJUDGED); digits = 3), hit5 = "$hit/$(length(DEFJUDGED))")
end
