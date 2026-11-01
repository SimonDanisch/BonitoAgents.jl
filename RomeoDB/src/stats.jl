# Popularity, from the package servers' public request logs (one row per package,
# status and client type, over the past year). It ranks results: between two packages
# doing the same thing, the one people use is the better answer.

"""
    downloads!(idx; url) -> number of packages with statistics

Replace the `downloads` table with the current rollup: for each package, the distinct
addresses that fetched it outside CI, and all successful requests. A successful fetch is
a 200 or, far more often, a 302 redirecting to storage; an address counted under both is
counted twice, which is close enough for ranking.
"""
function downloads!(idx::Index;
                    url = "https://julialang-logs.s3.amazonaws.com/public_outputs/current/package_requests.csv.gz")
    io = IOBuffer()
    Downloads.download(url, io)
    seekstart(io)
    lines = eachline(CodecZlib.GzipDecompressorStream(io))
    col = Dict(strip(h, '"') => i for (i, h) in enumerate(split(first(lines), ',')))
    users, requests = Dict{String,Int}(), Dict{String,Int}()
    for l in lines
        f = split(l, ',')
        strip(f[col["status"]], '"') in ("200", "302") || continue
        uuid = String(strip(f[col["package_uuid"]], '"'))
        requests[uuid] = get(requests, uuid, 0) + parse(Int, f[col["request_count"]])
        if strip(f[col["client_type"]], '"') == "user"
            users[uuid] = get(users, uuid, 0) + parse(Int, f[col["request_addrs"]])
        end
    end
    SQLite.transaction(idx.db) do
        exec!(idx.db, "DELETE FROM downloads")
        ins = DBInterface.prepare(idx.db, "INSERT INTO downloads (uuid, users, requests) VALUES (?, ?, ?)")
        for (uuid, n) in requests
            DBInterface.execute(ins, (uuid, get(users, uuid, 0), n))
        end
    end
    return length(requests)
end
