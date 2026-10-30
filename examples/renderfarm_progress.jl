# Inside bt_julia_eval, BonitoProgress is available without changing the
# render project's dependencies. In a separate coordinator, call bt_progress
# with action="context", inherit its `env`, and launch Julia with
# `-L <julia_client>`. Keep that progress-only context local to the worker.

function renderfarm_with_progress(renderfarm!, job, pool; kwargs...)
    progress = BonitoProgress.progress("Render farm"; id="render-farm",unit="frames")
    try
        # VideoEditor's existing (done,total) callback accepts the job handle.
        status = renderfarm!(job,pool; kwargs...,progress)
        if status["paused"] || status["completed"] < status["total"]
            BonitoProgress.update!(progress,status["completed"];total=status["total"]==0 ? nothing : status["total"],status="paused")
        else
            BonitoProgress.finish!(progress)
        end
        return status
    catch e
        if e isa InterruptException
            BonitoProgress.cancel!(progress)
        else
            BonitoProgress.fail!(progress,sprint(showerror,e))
        end
        rethrow()
    finally
        # A detached coordinator must wait for its last update before exiting.
        BonitoProgress.flush_progress(progress) || @warn "Last render progress update is still pending"
    end
end

# Render and encoding are separate phases; don't infer encoding progress from
# finished frames. Give exportvideo!'s callback another job handle, with
# primary=false if it should remain secondary to the render-farm row.
