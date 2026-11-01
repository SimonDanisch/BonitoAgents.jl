# RomeoDB

An independent Julia package in the BonitoAgents monorepo. Run it in its own Julia
environment; the index, source cache and optional model data live outside this source
directory. BonitoAgents' CPU-only integration environment is `BonitoAgents/test/romeodbenv`.

An index of the Julia ecosystem, made to stop rewriting what already exists: every
function, macro, type and constant of the latest version of every package in the
General registry (12k packages, 2.3M definitions), with docstrings, READMEs and
Documenter pages, dependencies, download counts, and a canonical form of each
definition for finding copies and near copies across packages. It reads source only;
no package code runs.

## Asking it

As an MCP server, which is how agents use it:

```sh
claude mcp add --scope user romeodb -- \
    julia --project=/path/to/env --startup-file=no --threads=8 \
    -e 'using RomeoDB; RomeoDB.serve(ARGS[1])' /path/to/data
```

Tools: `search` (definitions by what they do), `search_packages` (packages for a
topic, `gpu` to keep GPU-capable ones), `find_existing` (complete function bodies plus
their purpose, returning code matches, possible implementations and relevant packages),
`similar_code` (what exists like this code),
`definition` (docstring and source), `implementers` (methods of a generic function
across packages), `package_info`, `dependents`, and `audit_package` (functions of a
local package that duplicate ecosystem code). Both searches take `alternatives`: for a
need whose name is unclear ("contact sim"), the agent passes the phrasings an expert
might use ("frictional contact", "collision response", "multibody dynamics"), and what
several of them find ranks first.

From Julia:

```julia
using RomeoDB
idx = RomeoDB.Index("/path/to/data")
RomeoDB.search(idx, "\"prefix sum\""; gpu = true)          # synonyms (scan, accumulate, …) included
RomeoDB.packages(idx, "\"finite element\" assembly"; gpu = true)
RomeoDB.packages(idx, ["ocean sim", "ocean model", "ocean circulation"])   # phrasings of one need
RomeoDB.implementers(idx, "Adapt.adapt_structure")
tbl = RomeoDB.sketches(idx)                                 # 50 MB, 1 s; for the similarity queries
RomeoDB.similar_code(idx, tbl, read("myhelper.jl", String))
RomeoDB.audit(idx, tbl, "dev/MyPackage")
```

## Building it

```julia
idx = RomeoDB.Index("/path/to/data")          # SQLite file and source cache
RomeoDB.build!(idx, RomeoDB.latest_versions())  # ~20 min from scratch, resumes when interrupted
RomeoDB.downloads!(idx)                       # popularity from the package servers' public logs
```

Sources come from the package server by tree hash and are cached (2–3 GB); the index
is one SQLite file (~1.5 GB). A package already indexed under its tree hash is skipped,
so an interrupted `build!` resumes where it stopped.

## Keeping it current

```sh
julia --project=/path/to/env -e 'using Pkg, RomeoDB
    Pkg.Registry.update("General")
    RomeoDB.update!(RomeoDB.Index(ARGS[1]))' /path/to/data
```

`update!` indexes new packages and releases, drops the versions they replace (and their
cached sources), retries failed fetches and refreshes the download statistics: about
30 s for a day of registry changes. A running MCP server notices the change and reads
the similarity sketches again on its next query.

## Ranking by meaning

Word matching misses a package that describes the need in other words ("macro for data
wrangling" against DataFramesMeta's "macro functions which simplify the syntax required
to operate on DataFrames"). With an embedder, each package also gets a vector, and the
query's nearest packages are fused into the ranking:

```julia
using RomeoDB, Qwen3EmbeddingRunner          # JuliaVision's Qwen3-Embedding 0.6B, on Mantle
idx = RomeoDB.Index("/path/to/data")
m = qwen3embedding()
RomeoDB.embed_packages!(idx, m)              # ~20 min for 12.7k packages on a Radeon 8060S
sem = RomeoDB.Semantic(m, RomeoDB.packagevectors(idx))
RomeoDB.packages(idx, "ocean sim"; semantic = sem)
```

The runner downloads its graph, weights and tokenizer through its `Artifacts.toml`
on first use (873 MB compressed), then reuses Julia's artifact cache. Workers do not
need Python, a local model export or manual weight installation. RomeoDB's core
does not depend on the runner or download the model.

`update!(idx; embedder = m)` embeds what is new. The MCP server loads the model in the
background, `RomeoDB.serve(dir; embedder = RomeoDB.loadqwen3embedding)`, and searches use it
once it is ready. Start Julia with `--threads=8` as above so the request loop can
answer while the main thread loads the GPU packages. Searches use word matching until
the model has loaded and warmed up; stderr logs `RomeoDB: semantic search ready` when
they begin using embeddings too. For a headless server, set `JULIA_GLFW_PLATFORM=null`
in its environment: Mantle imports GLFW even for compute without a window.
On the judged queries in `eval/` it takes package search from MRR
0.764 to 0.852.

## Your own unregistered packages

```julia
RomeoDB.addlocal!(idx, "/path/to/work/dev")   # a package, or a folder of packages
RomeoDB.removelocal!(idx, "/path/to/work/dev")
```

The unregistered packages in these folders are indexed with the registry's and read
again on every `update!`. Results mark them `local` and give their files' absolute
paths. Checkouts of registered packages are skipped: the registry's version stands for
them.

## How code is compared

Each definition becomes a pre-order token stream over its syntax tree. `exact` hashes
it as written (whitespace and comments aside); `renamed` hashes it with the names it
binds (arguments, locals, type parameters, its own name) numbered by first use and
literals reduced to their kind; a 256-bit one-permutation MinHash of its 4-token
shingles estimates the Jaccard similarity of two definitions by Hamming distance, which
a brute-force scan of all 1.6M sketches answers in ~20 ms.
