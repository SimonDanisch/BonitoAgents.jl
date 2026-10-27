# One durable record per job. Observers consume snapshots, never transcript
# messages or turn signals: progress cannot steer the agent or rebuild a sidebar.
mutable struct JobBook
    lock::ReentrantLock
    changed::Observable{Dict{String,Any}}
    path::String
    last_saved::Float64
end

function job_book(state, pid)
    state = root_state(state)
    lock(state.lock) do
        get!(state.job_progress,String(pid)) do
            path = joinpath(state.state_dir,"chats",pid,"progress.json")
            stored = load_json_tolerant(path,"job progress")
            jobs = stored === nothing ? Dict{String,Any}() : Dict{String,Any}(stored)
            for job in values(jobs); job["connected"]=false; end
            JobBook(ReentrantLock(),Observable(jobs),path,0.0)
        end
    end
end

function save_jobs!(book)
    atomic_write_json(book.path,book.changed[])
    book.last_saved = time()
    return nothing
end

function validate_job(frame)
    for key in ("id","generation","label","status","parent","unit","detail")
        value = get(frame,key,nothing)
        value isa AbstractString && ncodeunits(value) <= (key=="detail" ? 4096 : 256) ||
            throw(ArgumentError("invalid job $key"))
    end
    isempty(frame["id"]) && throw(ArgumentError("job id cannot be empty"))
    isempty(frame["generation"]) && throw(ArgumentError("job generation cannot be empty"))
    frame["status"] in ("running","paused","completed","failed","cancelled","closed") ||
        throw(ArgumentError("invalid job status"))
    seq = get(frame,"seq",nothing)
    seq isa Integer && !(seq isa Bool) && seq > 0 || throw(ArgumentError("invalid progress sequence"))
    completed = get(frame,"completed",nothing)
    completed isa Real && isfinite(completed) && completed >= 0 || throw(ArgumentError("invalid completed count"))
    total = get(frame,"total",nothing)
    total === nothing || (total isa Real && isfinite(total) && total > 0 && completed <= total) ||
        throw(ArgumentError("invalid total count"))
    get(frame,"primary",nothing) isa Bool || throw(ArgumentError("invalid primary flag"))
    return nothing
end

function job_update!(book::JobBook, frame, worker, connection)
    validate_job(frame)
    lock(book.lock) do
        jobs = copy(book.changed[])
        prior = get(jobs,frame["id"],nothing)
        retired = prior === nothing ? String[] : get(prior,"retired_generations",String[])
        frame["generation"] in retired && return nothing
        if prior !== nothing && prior["generation"] == frame["generation"]
            frame["seq"] < prior["seq"] && return nothing
            # A reconnect may replay the latest acknowledged state; reconnect
            # the indicator without allowing an older terminal state to revive.
            if frame["seq"] == prior["seq"]
                jobs[frame["id"]] = merge(prior,Dict("connected"=>true,"connection"=>connection))
                book.changed[] = jobs
                return nothing
            end
            prior["status"] in ("running","paused") || return nothing
        elseif prior !== nothing
            retired = last([retired;prior["generation"]],16)
        end
        if prior === nothing && length(jobs) >= 64
            finished = sort([j for j in values(jobs) if !(j["status"] in ("running","paused")) &&
                (j["status"] != "failed" || get(j,"dismissed",false))]; by=j->j["updated_at"])
            isempty(finished) && throw(ArgumentError("too many active or unacknowledged jobs"))
            delete!(jobs,first(finished)["id"])
        end
        record = Dict{String,Any}(String(k)=>v for (k,v) in frame if k in
            ("id","generation","seq","label","status","parent","unit","detail","completed","total","primary"))
        record["worker"] = String(worker)
        record["connection"] = String(connection)
        record["connected"] = true
        record["worker_online"] = true
        record["updated_at"] = time() # server time; workers' clocks may differ
        continuing = prior !== nothing && prior["generation"] == frame["generation"]
        record["started_at"] = continuing ? get(prior,"started_at",record["updated_at"]) : record["updated_at"]
        delta = continuing ? record["completed"]-prior["completed"] : 0.0
        elapsed = continuing ? record["updated_at"]-prior["updated_at"] : 0.0
        record["samples"] = continuing && delta > 0 ? get(prior,"samples",0)+1 : 0
        rate = continuing && delta > 0 && elapsed > 0 ? delta/elapsed : 0.0
        record["rate"] = rate > 0 ? (get(prior === nothing ? Dict() : prior,"rate",0.0)>0 ?
            0.75*prior["rate"]+0.25*rate : rate) : 0.0
        record["dismissed"] = prior !== nothing && prior["generation"] == frame["generation"] && get(prior,"dismissed",false)
        record["retired_generations"] = retired
        jobs[frame["id"]] = record
        book.changed[] = jobs
        # Running snapshots are checkpointed at most once per second; terminal
        # state and channel closure are always persisted immediately.
        (time()-book.last_saved >= 1 || !(record["status"] in ("running","paused"))) && save_jobs!(book)
    end
    return nothing
end

function progress_worker_connected!(state, worker, online)
    state = root_state(state)
    books = lock(() -> collect(values(state.job_progress)),state.lock)
    for book in books
        lock(book.lock) do
            jobs = copy(book.changed[])
            changed = false
            for (id,job) in jobs
                get(job,"worker",nothing) == worker || continue
                jobs[id] = merge(job,Dict("worker_online"=>online))
                changed = true
            end
            changed && (book.changed[]=jobs)
        end
    end
    return nothing
end

function progress_disconnected!(book, connection)
    lock(book.lock) do
        jobs = copy(book.changed[])
        for (id,job) in jobs
            get(job,"connection",nothing) == connection || continue
            jobs[id] = merge(job,Dict("connected"=>false))
        end
        book.changed[] = jobs
        save_jobs!(book)
    end
    return nothing
end

# Tool-driven sync uses the same durable job snapshots as worker computations.
# File counts measure the chosen manifest; byte counts are actual relayed data
# (including deltas), never a guessed fraction of the source's logical size.
function sync_job_progress(state, pid, worker, label)
    book = job_book(state, pid)
    generation = string(uuid4())
    frame = Dict{String,Any}("id" => "sync-$generation", "generation" => generation,
        "seq" => 0, "label" => first(label, 256), "status" => "running", "parent" => "",
        "unit" => "files", "detail" => "", "completed" => 0, "total" => nothing, "primary" => true)
    last_sent = 0.0
    files = 0
    skipped = 0
    bytes = 0
    current_file = ""
    return function(stage, info)
        if stage === :phase
            frame["detail"] = info.msg
        elseif stage === :manifest_received
            files = info.count
            frame["total"] = files > 0 ? files : nothing
            frame["detail"] = "Planning $files files"
        elseif stage === :plan_received
            skipped = files - info.work
            frame["completed"] = skipped
        elseif stage === :file_start
            current_file = info.rel
        elseif stage === :file_chunk
            bytes += info.bytes
        elseif stage === :file_done
            frame["completed"] = skipped + info.idx
        elseif stage === :transfer_done
            frame["detail"] = "Confirming destination writes"
        elseif stage in (:completed, :failed, :cancelled)
            frame["status"] = String(stage)
            frame["detail"] = info.msg
        else
            return nothing
        end
        if stage in (:file_start, :file_chunk, :file_done)
            frame["detail"] = first("$current_file · $(Base.format_bytes(bytes)) transferred", 4096)
        end
        now = time()
        frame["status"] == "running" && now - last_sent < 0.2 && return nothing
        last_sent = now
        frame["seq"] += 1
        job_update!(book, frame, worker, "server-sync-$generation")
        return nothing
    end
end

function serve_progress_channel(state, channel, pid, worker)
    book = job_book(state,pid)
    connection = string(uuid4())
    try
        for raw in channel
            try
                frame = JSON.parse(String(raw))
                job_update!(book,frame,worker,connection)
                HTTP.WebSockets.send(channel,"ok $(frame["seq"])")
            catch e
                e isa InterruptException && rethrow()
                HTTP.WebSockets.send(channel,"error: $(sprint(showerror,e))")
            end
        end
    catch e
        e isa HTTP.WebSockets.WebSocketError || rethrow()
    finally
        progress_disconnected!(book,connection)
    end
    return nothing
end

# Both widgets use one snapshot and shared renderer. JS only changes text,
# SVG attributes and native progress values; no node is replaced per tick.
function job_progress_view(session, book; icon=false)
    node = if icon
        DOM.div(; class="bt-job-icon",hidden=true)
    else
        DOM.details(
            DOM.summary(DOM.span(;class="bt-job-label"),DOM.span(;class="bt-job-count"),
                DOM.strong(;class="bt-job-percent"),DOM.progress(;class="bt-job-bar",max=1);
                class="bt-job-summary"),
            DOM.div(DOM.div(;class="bt-job-status"),DOM.div(;class="bt-job-detail-text"),
                DOM.div(;class="bt-job-list"),
                DOM.button("Dismiss";class="bw-btn bw-btn-ghost bw-btn-sm",type="button");class="bt-job-detail");
            class="bt-job-progress",hidden=true)
    end
    dismiss = Observable(Dict{String,Any}())
    on(session,dismiss) do request
        isempty(request) && return
        lock(book.lock) do
            jobs = copy(book.changed[])
            job = get(jobs,get(request,"id",""),nothing)
            job === nothing && return
            job["generation"] == get(request,"generation",nothing) || return
            jobs[job["id"]] = merge(job,Dict("dismissed"=>true))
            book.changed[] = jobs
            save_jobs!(book)
        end
    end
    data = map(identity,session,book.changed)
    Bonito.onload(session,node,js"""el => {
        const data = $(data), icon = $(icon), dismiss = $(dismiss);
        let selected = null;
        if (icon) {
            const ns='http://www.w3.org/2000/svg';
            const svg=document.createElementNS(ns,'svg');
            svg.setAttribute('viewBox','0 0 48 48'); svg.setAttribute('class','bt-job-ring');
            svg.setAttribute('aria-hidden','true');
            for (const cls of ['bt-job-ring-track','bt-job-ring-fill']) {
                const rect=document.createElementNS(ns,'rect');
                for (const [key,value] of Object.entries({x:2,y:2,width:44,height:44,rx:13,fill:'none',pathLength:100,class:cls}))
                    rect.setAttribute(key,String(value));
                if (cls==='bt-job-ring-fill') rect.setAttribute('stroke-dasharray','100');
                svg.append(rect);
            }
            el.append(svg);
        }
        const active = j => ['running','paused','failed'].includes(j.status);
        const render = value => {
            const jobs=Object.values(value).filter(j=>!j.dismissed).sort((a,b)=>
                Number(active(b))-Number(active(a)) || Number(b.primary)-Number(a.primary) ||
                (active(a) ? a.started_at-b.started_at : b.updated_at-a.updated_at));
            selected=jobs[0] || null;
            el.hidden=!selected;
            if (!selected) return;
            const j=selected, known=j.total!==null, fraction=known ? Math.min(1,j.completed/j.total) : null;
            const offline=['running','paused'].includes(j.status) && (!j.connected || j.worker_online===false);
            const percent=known ? Math.floor(fraction*100)+'%' :
                ({completed:'Done',paused:'Paused',failed:'Failed',cancelled:'Stopped',closed:'Ended'})[j.status] || '…';
            const label=j.label || 'Job progress';
            el.dataset.jobId=j.id; el.dataset.status=offline ? 'offline' : j.status;
            el.dataset.indeterminate=String(!known && j.status==='running' && !offline);
            const status=offline ? 'Disconnected · last known progress' :
                ({running:'Running',paused:'Paused',completed:'Completed',failed:'Failed',cancelled:'Cancelled',closed:'Ended before completion'})[j.status];
            el.title=label+' · '+percent+' · '+status;
            el.setAttribute('aria-label',el.title);
            if (icon) {
                el.querySelector('.bt-job-ring-fill').setAttribute('stroke-dashoffset',100-(fraction===null ? 20 : fraction*100));
            } else {
                el.querySelector('.bt-job-label').textContent=label+(jobs.length>1 ? ' · +'+(jobs.length-1) : '');
                el.querySelector('.bt-job-count').textContent=known ? j.completed.toLocaleString()+' / '+j.total.toLocaleString()+(j.unit ? ' '+j.unit : '') : '';
                el.querySelector('.bt-job-percent').textContent=percent;
                const bar=el.querySelector('progress');
                if (known) bar.value=fraction;
                else if (j.status==='running' && !offline) bar.removeAttribute('value');
                else bar.value=0;
                bar.setAttribute('aria-label',label+' · '+status);
                const seconds=known && j.rate>0 && j.samples>=3 && j.updated_at-j.started_at>=5 ? (j.total-j.completed)/j.rate : null;
                const eta=seconds!==null && j.status==='running' && !offline ? ' · ETA ~'+(seconds>=60 ? Math.ceil(seconds/60)+' min' : Math.ceil(seconds)+' s') : '';
                el.querySelector('.bt-job-status').textContent=status+eta;
                el.querySelector('.bt-job-detail-text').textContent=j.detail || '';
                el.querySelector('.bt-job-list').textContent=jobs.slice(1).map(other=>
                    other.label+' · '+(other.total===null ? other.status : Math.floor(other.completed/other.total*100)+'%')).join('\n');
            }
        };
        if (!icon) el.querySelector('button').onclick=event=>{
            event.preventDefault(); if (selected) dismiss.notify({id:selected.id,generation:selected.generation});
        };
        data.on(render); render(data.value);
    }""")
    return DOM.div(JobProgressStyles,node;class="bt-job-slot")
end

const JobProgressStyles = Styles(
    CSS(".bt-job-slot", "display"=>"contents"),
    CSS(".bt-job-progress", "margin"=>"0 var(--bw-space-3) var(--bw-space-2)",
        "border"=>"1px solid var(--bw-border)", "border-radius"=>"var(--bw-radius)",
        "background"=>"var(--bw-bg-panel)", "flex-shrink"=>"0", "overflow"=>"hidden"),
    CSS(".bt-job-progress[hidden], .bt-job-icon[hidden]", "display"=>"none"),
    CSS(".bt-job-summary", "display"=>"grid", "grid-template-columns"=>"minmax(0,1fr) auto auto",
        "gap"=>"var(--bw-space-1) var(--bw-space-2)", "padding"=>"var(--bw-space-2) var(--bw-space-3)",
        "cursor"=>"pointer", "list-style"=>"none", "align-items"=>"center"),
    CSS(".bt-job-summary::-webkit-details-marker", "display"=>"none"),
    CSS(".bt-job-label", "font-size"=>"var(--bw-font-size-ui)", "font-weight"=>"500",
        "white-space"=>"nowrap", "overflow"=>"hidden", "text-overflow"=>"ellipsis"),
    CSS(".bt-job-label::before", "content"=>"'▸ '", "color"=>"var(--bw-text-muted)"),
    CSS(".bt-job-progress[open] .bt-job-label::before", "content"=>"'▾ '"),
    CSS(".bt-job-count", "color"=>"var(--bw-text-muted)", "font-size"=>"var(--bw-font-size-xs)", "white-space"=>"nowrap"),
    CSS(".bt-job-percent", "font-size"=>"var(--bw-font-size-xs)", "font-variant-numeric"=>"tabular-nums"),
    CSS(".bt-job-bar", "grid-column"=>"1 / -1", "height"=>"3px", "width"=>"100%",
        "appearance"=>"none", "border"=>"0", "border-radius"=>"var(--bw-radius-sm)", "overflow"=>"hidden"),
    CSS(".bt-job-bar::-webkit-progress-bar", "background"=>"var(--bw-bg-subtle)"),
    CSS(".bt-job-bar::-webkit-progress-value", "background"=>"var(--bw-accent)"),
    CSS(".bt-job-bar::-moz-progress-bar", "background"=>"var(--bw-accent)"),
    CSS(".bt-job-detail", "padding"=>"var(--bw-space-2) var(--bw-space-3)",
        "border-top"=>"1px solid var(--bw-border)", "font-size"=>"var(--bw-font-size-ui)",
        "max-height"=>"30vh", "overflow"=>"auto"),
    CSS(".bt-job-detail-text, .bt-job-list", "white-space"=>"pre-wrap", "overflow-wrap"=>"anywhere",
        "color"=>"var(--bw-text-muted)", "margin-top"=>"var(--bw-space-1)"),
    CSS(".bt-side-icon-wrap", "position"=>"relative"),
    CSS(".bt-job-icon", "position"=>"absolute", "inset"=>"-4px", "cursor"=>"pointer"),
    CSS(".bt-job-ring", "width"=>"100%", "height"=>"100%", "overflow"=>"visible"),
    CSS(".bt-job-ring-track", "stroke"=>"var(--bw-border)", "stroke-width"=>"2.5"),
    CSS(".bt-job-ring-fill", "stroke"=>"var(--bw-accent)", "stroke-width"=>"2.5",
        "stroke-linecap"=>"round", "transition"=>"stroke-dashoffset 180ms ease"),
    CSS(".bt-job-icon[data-status='failed'] .bt-job-ring-fill", "stroke"=>"var(--bw-error)"),
    CSS(".bt-job-icon[data-status='completed'] .bt-job-ring-fill", "stroke"=>"var(--bw-success)"),
    CSS(".bt-job-icon[data-status='offline'] .bt-job-ring-fill", "stroke"=>"var(--bw-text-faint)"),
    CSS(".bt-job-progress[data-status='failed'] .bt-job-status", "color"=>"var(--bw-error)"),
    CSS(".bt-job-icon[data-indeterminate='true'] .bt-job-ring-fill", "stroke-dasharray"=>"20 80",
        "animation"=>"bt-job-travel 2s linear infinite"),
    CSS("@keyframes bt-job-travel", CSS("from","stroke-dashoffset"=>"100"), CSS("to","stroke-dashoffset"=>"0")),
    CSS("@media (prefers-reduced-motion: reduce)", CSS(".bt-job-ring-fill","animation"=>"none !important","transition"=>"none !important")),
    CSS("@media (max-width: 640px)", CSS(".bt-job-progress", "margin-left"=>"var(--bw-space-2)","margin-right"=>"var(--bw-space-2)"),
        CSS(".bt-job-summary", "column-gap"=>"var(--bw-space-1)","padding-left"=>"var(--bw-space-2)","padding-right"=>"var(--bw-space-2)"))
)
