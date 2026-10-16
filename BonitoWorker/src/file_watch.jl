# ── Following a file for the server ─────────────────────────────────────────
# A background task writes to a file the server follows: a shell's output
# redirect, a subagent's transcript. The server used to ask for it once a second
# per task, and every answer scanned every process on the machine
# for who still held the file open: 0.2 s of CPU per task per second. Here the
# worker follows the file and says what changed, when it changes:
#
#     open {kind:"watch_file", path, offset, until:"closed"|"marker", marker}
#     ->   {ok:true}
#     then {chunk, offset}     bytes appended since `offset` (until = "closed")
#          {done:true, offset} the writer closed the file / `marker` appeared
#
# The watch ends with `done`, or when the server closes the channel.
#
# "closed" needs to know when the last writer let go of the file. On Linux the
# kernel says when a writer closes it (inotify IN_CLOSE_WRITE), and the process
# scan runs on that event only, to tell the last close from an earlier one.
# Elsewhere there is no close event: the bytes stream, and the task stays until
# the user stops it, as it did before.

const IN_MODIFY      = UInt32(0x00000002)
const IN_CLOSE_WRITE = UInt32(0x00000008)
const IN_MOVED_TO    = UInt32(0x00000080)
const IN_CREATE      = UInt32(0x00000100)
const IN_DELETE_SELF = UInt32(0x00000400)
const IN_MOVE_SELF   = UInt32(0x00000800)

struct InotifyEvent
    wd::Int32
    mask::UInt32
    name::String
end

# An inotify instance, waited on through libuv: no thread sits in a read.
mutable struct Inotify
    fd::Cint
    watcher::FileWatching.FDWatcher
    closed::Threads.Atomic{Bool}
end

function Inotify()
    fd = ccall(:inotify_init1, Cint, (Cint,), Cint(0o4000) | Cint(0o2000000))  # IN_NONBLOCK | IN_CLOEXEC
    fd < 0 && Base.systemerror("inotify_init1")
    return Inotify(fd, FileWatching.FDWatcher(RawFD(fd), true, false), Threads.Atomic{Bool}(false))
end

function add_watch!(ino::Inotify, path::AbstractString, mask::UInt32)
    wd = ccall(:inotify_add_watch, Cint, (Cint, Cstring, UInt32), ino.fd, path, mask)
    wd < 0 && Base.systemerror("inotify_add_watch $(path)")
    return wd
end

# Once only: a second close of the number could hit a file opened since.
function Base.close(ino::Inotify)
    Threads.atomic_xchg!(ino.closed, true) && return nothing
    close(ino.watcher)
    ccall(:close, Cint, (Cint,), ino.fd)
    return nothing
end

# The next batch of events. Throws `EOFError` once `ino` is closed.
function next_events(ino::Inotify)
    buf = Vector{UInt8}(undef, 64 * 1024)
    while true
        wait(ino.watcher)
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), ino.fd, buf, length(buf))
        if n < 0
            Libc.errno() == Libc.EAGAIN && continue
            Base.systemerror("read inotify")
        end
        events = InotifyEvent[]
        i = 1
        while i + 15 <= n
            wd, mask, _, len = reinterpret(UInt32, buf[i:(i + 15)])
            raw = buf[(i + 16):(i + 15 + len)]
            push!(events, InotifyEvent(reinterpret(Int32, wd), mask, String(raw[1:something(findfirst(==(0x00), raw), len + 1) - 1])))
            i += 16 + len
        end
        return events
    end
end

# The bytes of `path` from `offset` on, at most `max_bytes` of them.
function read_from(path::AbstractString, offset::Int; max_bytes::Int = 1 << 20)
    return open(path, "r") do io
        sz = filesize(io)
        offset >= sz && return UInt8[]
        seek(io, offset)
        read(io, min(max_bytes, sz - offset))
    end
end

send_watch(ch, msg::AbstractDict) = WebSockets.send(ch, MsgPack.pack(msg))

# Send what was appended since `offset`; returns the new offset.
function send_appended!(ch, path::AbstractString, offset::Int)
    while true
        bytes = read_from(path, offset)
        isempty(bytes) && return offset
        offset += length(bytes)
        send_watch(ch, Dict("chunk" => String(bytes), "offset" => offset))
    end
end

# Until `path` exists: a shell's redirect is created after the agent names it.
# Returns whether it had to wait.
function wait_created(ino::Inotify, path::AbstractString)
    isfile(path) && return false
    add_watch!(ino, dirname(path), IN_CREATE | IN_MOVED_TO)
    name = basename(path)
    while !isfile(path)          # it may have appeared before the watch did
        any(e -> e.name == name, next_events(ino)) && break
    end
    return true
end

nobody_writes(path) = isempty(file_writer_pids(path))

function watch_until_closed(ch, path::AbstractString, offset::Int, ino::Inotify)
    created = wait_created(ino, path)
    add_watch!(ino, path, IN_MODIFY | IN_CLOSE_WRITE | IN_DELETE_SELF | IN_MOVE_SELF)
    offset = send_appended!(ch, path, offset)
    # A file that was there already may belong to a task that ended before the
    # watch began. One that appeared just now has nobody writing it until its
    # creator hands it on, so only its close can say it is over.
    created || !nobody_writes(path) || return send_watch(ch, Dict("done" => true, "offset" => offset))
    while true
        events = next_events(ino)
        any(e -> e.mask & IN_MODIFY != 0, events) && (offset = send_appended!(ch, path, offset))
        # Moved or deleted: nothing more will be written where we look.
        any(e -> e.mask & (IN_DELETE_SELF | IN_MOVE_SELF) != 0, events) && return nothing
        if any(e -> e.mask & IN_CLOSE_WRITE != 0, events) && nobody_writes(path)
            offset = send_appended!(ch, path, offset)
            return send_watch(ch, Dict("done" => true, "offset" => offset))
        end
    end
end

# What a watch waits on right now, so the server letting go can end the wait:
# closing a watcher ends its `wait` with an `EOFError`.
mutable struct WatchStop
    stopped::Bool
    current::Any                  # an Inotify, FileMonitor or FolderMonitor; or nothing
    lock::ReentrantLock
end
WatchStop() = WatchStop(false, nothing, ReentrantLock())

# Open a watcher under `stop`; an already stopped watch gets an EOFError at once.
function watching!(open_watcher, stop::WatchStop)
    w = open_watcher()
    stopped = lock(stop.lock) do
        stop.stopped || (stop.current = w)
        stop.stopped
    end
    stopped && (close(w); throw(EOFError()))
    return w
end

function stop!(stop::WatchStop)
    w = lock(stop.lock) do
        stop.stopped = true
        stop.current
    end
    w === nothing || close(w)
    return nothing
end

# Without a close event: `f()` on every change, until it returns true.
function watch_changes(f, path::AbstractString, stop::WatchStop)
    fm = watching!(() -> FileWatching.FileMonitor(path), stop)
    try
        while !f()
            wait(fm)
        end
    finally
        close(fm)
    end
    return nothing
end

function wait_file(path::AbstractString, stop::WatchStop)
    isfile(path) && return nothing
    fm = watching!(() -> FileWatching.FolderMonitor(dirname(path)), stop)
    try
        while !isfile(path)      # it may have appeared before the watch did
            wait(fm)
        end
    finally
        close(fm)
    end
    return nothing
end

function watch_until_marker(ch, path::AbstractString, offset::Int, marker::AbstractString, stop::WatchStop)
    wait_file(path, stop)
    # Re-read the marker's length before `offset`, so one split across two reads is found.
    from = max(0, offset - ncodeunits(marker))
    watch_changes(path, stop) do
        bytes = read_from(path, from; max_bytes = typemax(Int))
        found = occursin(marker, String(copy(bytes)))
        found && send_watch(ch, Dict("done" => true, "offset" => from + length(bytes)))
        from = max(from, from + length(bytes) - ncodeunits(marker))
        found
    end
end

"""
    run_file_watch(ch, header)

Serve a `watch_file` channel: follow `header["path"]` and report to the server
until it is done or the server closes the channel.
"""
function run_file_watch(ch::WorkerLink.LinkChannel, header::AbstractDict)
    path = String(header["path"])
    offset = Int(get(header, "offset", 0))
    until = String(get(header, "until", "closed"))
    channel_ready(ch)
    stop = WatchStop()
    # The server closing the channel ends the watch, wherever it waits.
    errormonitor(@async begin
        try
            WebSockets.receive(ch)
        catch e
            e isa WebSockets.WebSocketError || rethrow()
        end
        stop!(stop)
    end)
    try
        if until == "marker"
            watch_until_marker(ch, path, offset, String(header["marker"]), stop)
        elseif Sys.islinux()
            ino = watching!(Inotify, stop)
            try
                watch_until_closed(ch, path, offset, ino)
            finally
                close(ino)
            end
        else
            watch_changes(path, stop) do
                offset = send_appended!(ch, path, offset)
                false
            end
        end
    catch e
        # The server let go: the closed watcher's EOFError, or a send on the
        # channel it closed.
        (e isa EOFError || e isa WebSockets.WebSocketError) || rethrow()
    finally
        stop!(stop)
        isopen(ch) && close(ch)
    end
    return nothing
end
