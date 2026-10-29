# How well package search answers task-level questions, on a built index: for each query,
# packages an expert would name. Run after changing the ranking:
#
#     using RomeoDB; include("eval/package_search.jl"); evaluate(RomeoDB.Index("/path/to/data"))
#
# Scored on 2026-10-28 (12.7k packages): MRR 0.764, a judged package in the top 5 for
# 34 of 37 queries, recall@10 0.622. The ranking before package documents were fused in
# scored 0.439, 31/37 and 0.419. With Qwen3-Embedding's package vectors fused in
# (`semantic = RomeoDB.Semantic(qwen3embedding(), RomeoDB.packagevectors(idx))`): 0.852,
# 36/37 and 0.678; the embeddings alone score 0.573, 30/37 and 0.511.

using RomeoDB

const JUDGED = [
    "ocean simulation" => ["Oceananigans", "ClimaOcean", "NumericalEarth", "ShallowWaters"],
    "ocean sim" => ["Oceananigans", "ClimaOcean", "NumericalEarth", "ShallowWaters"],
    "contact simulation" => ["Dojo", "MuJoCo", "DifferentiableCollisions", "ContactImplicitMPC", "ConstrainedDynamics",
                             "Modia3D", "RoboDojo"],
    "contact sim" => ["Dojo", "MuJoCo", "DifferentiableCollisions", "ContactImplicitMPC", "ConstrainedDynamics", "Modia3D",
                      "RoboDojo"],
    "fluid simulation" => ["WaterLily", "Trixi", "IncompressibleNavierStokes", "XCALibre", "Oceananigans", "TrixiParticles",
                           "ShallowWaters"],
    "weather model" => ["SpeedyWeather", "ClimaAtmos"],
    "rigid body physics" => ["RigidBodyDynamics", "Dojo", "MuJoCo", "ConstrainedDynamics", "RigidBodyTools", "Modia3D",
                             "RigidBodySim"],
    "point cloud" => ["PointClouds", "PointCloudRegistration", "LASDatasets", "Displaz", "Flux3D"],
    "path planning" => ["HybridAStar", "AStarGridSearch", "ProbabilisticRoadMap", "Graphs", "AStarSearch"],
    "particle simulation" => ["TrixiParticles", "Molly", "NBodySimulator", "CellListMap", "InPartS", "AstroNbodySim"],
    "optimize a function" => ["Optim", "Optimization", "NLopt", "JuMP", "Ipopt", "BlackBoxOptim", "Metaheuristics",
                              "Evolutionary"],
    "read stl files" => ["MeshIO", "FileIO"],
    "finite element" => ["Ferrite", "Gridap", "FinEtools", "ExtendableFEM", "JuliaFEM", "MinFEM", "LowLevelFEM"],
    "molecular dynamics" => ["Molly", "NQCDynamics", "InteratomicPotentials", "ExTinyMD", "AtomsBase", "CellListMap"],
    "neural network" => ["Flux", "Lux", "Knet", "SimpleChains", "NNlib"],
    "image segmentation" => ["ImageSegmentation", "SegmentAnything"],
    "ray tracing" => ["Raycore", "Hikari", "RayTracer", "OpticSim", "ImplicitBVH"],
    "mesh generation" => ["Gmsh", "TetGen", "Triangulate", "DelaunayTriangulation", "HOHQMesh", "GridapGmsh", "Meshes"],
    "sparse linear solver" => ["LinearSolve", "Krylov", "KLU", "Pardiso", "IterativeSolvers", "MUMPS", "CUDSS",
                               "AlgebraicMultigrid", "Sparspak"],
    "audio processing" => ["WAV", "SampledSignals", "DSP", "MusicProcessing", "LibSndFile"],
    "solve differential equations" => ["DifferentialEquations", "OrdinaryDiffEq"],
    "plotting" => ["Plots", "Makie", "GLMakie", "CairoMakie", "UnicodePlots"],
    "gpu programming" => ["CUDA", "KernelAbstractions", "AMDGPU", "Metal", "GPUArrays", "oneAPI"],
    "automatic differentiation" => ["ForwardDiff", "Zygote", "Enzyme", "ReverseDiff", "Mooncake", "DifferentiationInterface"],
    "data frames" => ["DataFrames"],
    "read csv" => ["CSV"],
    "web server" => ["HTTP", "Oxygen", "Genie", "Mux"],
    "symbolic math" => ["Symbolics", "SymPy", "ModelingToolkit", "SymbolicUtils"],
    "graph algorithms" => ["Graphs", "SimpleWeightedGraphs"],
    "probability distributions" => ["Distributions"],
    "linear programming" => ["JuMP", "HiGHS", "GLPK", "Clp", "Tulip"],
    "quantum computing" => ["Yao", "QuantumClifford", "Snowflurry"],
    "gaussian process" => ["GaussianProcesses", "AbstractGPs", "KernelFunctions", "Stheno"],
    "fourier transform" => ["FFTW", "AbstractFFTs"],
    "interpolation" => ["Interpolations", "DataInterpolations"],
    "random forest" => ["DecisionTree", "MLJ"],
    "image processing" => ["Images", "ImageFiltering", "ImageTransformations", "ImageCore"],
]

"""
    evaluate(idx; show = false, semantic = nothing) -> (mrr, hit5, recall10)

Mean reciprocal rank of the first judged package, how many queries have one in the top
5, and the mean share of the judged packages in the top 10. With `show`, each query's
rank of its first judged package and its top 5.
"""
function evaluate(idx::RomeoDB.Index; show::Bool = false, semantic = nothing)
    name = Dict(r.id => r.name for r in RomeoDB.rows(idx, "SELECT id, name FROM packages"))
    mrr, hit, recall = 0.0, 0, 0.0
    for (q, judged) in JUDGED
        ranked = [name[id] for id in RomeoDB.rankpackages(idx, q; semantic)]
        i = findfirst(in(judged), ranked)
        mrr += i === nothing ? 0.0 : 1 / i
        hit += i !== nothing && i <= 5
        recall += count(in(judged), ranked[1:min(end, 10)]) / min(length(judged), 10)
        show && println(rpad(q, 30), rpad(something(i, "-"), 4), join(ranked[1:min(end, 5)], ", "))
    end
    n = length(JUDGED)
    return (mrr = round(mrr / n; digits = 3), hit5 = "$hit/$n", recall10 = round(recall / n; digits = 3))
end
