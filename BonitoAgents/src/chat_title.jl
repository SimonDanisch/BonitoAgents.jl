# The inline-editable chat title: an <input> bound to the chat's one title
# observable (`ProjectInfo.title`), so wherever it renders it shows what every
# other view shows. Enter commits, Escape restores the shown value, and a blank
# edit clears the title back to the folder name. Build it once per view — the
# node is reused across re-renders of its host.
function chat_title_input(session::Bonito.Session, p::ProjectInfo;
                          class::AbstractString, tooltip::AbstractString)
    # A session child of the one title, so the tab's close tears it down.
    shown = map(identity, session, p.title)
    edit  = Observable("")
    on(session, edit) do v
        set_project_title!(p, v)
    end
    return DOM.input(; type = "text", class = class, value = shown, title = tooltip,
        onchange  = js"event => $(edit).notify(event.target.value)",
        onkeydown = js"""event => {
            if (event.key === 'Enter') { event.target.blur(); }
            else if (event.key === 'Escape') {
                event.target.value = $(shown).value;
                event.target.blur();
            }
        }""")
end
