"""
    FileToolbar(title; metadata=(), actions=(), class="", caption=false)

Compact file heading shared by chat previews, workspace files and public links.
Pass existing controls as `actions`; their styles come from the app's common
button and menu widgets. `caption=true` adopts a native chat preview's title.
For example, `FileToolbar("report.csv"; metadata="42 KB")` renders a file heading.
"""
struct FileToolbar
    title::Any
    metadata::Any
    actions::Any
    class::String
    caption::Bool
end
FileToolbar(title;metadata=(),actions=(),class="",caption=false) =
    FileToolbar(title,metadata,actions,String(class),caption)

const FILE_TOOLBAR_CSS = [
    CSS(".bt-file-toolbar-slot", "display"=>"contents"),
    CSS(".bt-file-toolbar", "display"=>"flex", "align-items"=>"center", "gap"=>"var(--bw-space-2)",
        "padding"=>"var(--bw-space-2) var(--bw-space-3)", "background"=>"var(--bw-bg-subtle)",
        "border-bottom"=>"1px solid var(--bw-border)", "color"=>"var(--bw-text)",
        "font-family"=>"system-ui, sans-serif", "font-size"=>"var(--bw-font-size-ui)", "min-width"=>"0"),
    CSS(".bt-file-toolbar-title", "flex"=>"1 1 auto", "min-width"=>"0", "font-weight"=>"500",
        "overflow"=>"hidden", "text-overflow"=>"ellipsis", "white-space"=>"nowrap"),
    CSS(".bt-file-toolbar-title > .bt-file-editor-path", "display"=>"block", "font-family"=>"inherit", "font-size"=>"inherit"),
    CSS(".bt-file-toolbar-meta", "display"=>"flex", "align-items"=>"center", "gap"=>"var(--bw-space-2)",
        "font-size"=>"var(--bw-font-size-xs)", "color"=>"var(--bw-text-muted)", "min-width"=>"0",
        "overflow"=>"hidden", "white-space"=>"nowrap", "text-overflow"=>"ellipsis"),
    CSS(".bt-file-toolbar-meta:empty", "display"=>"none"),
    CSS(".bt-file-toolbar-actions", "display"=>"flex", "align-items"=>"center", "gap"=>"var(--bw-space-1)",
        "flex"=>"0 0 auto"),
    CSS(".bt-file-toolbar .bt-share-control", "margin"=>"0", "flex-wrap"=>"nowrap"),
    CSS(".bt-file-toolbar .bt-media-actions", "position"=>"static", "opacity"=>"1", "transition"=>"none"),
    CSS(".bt-file-toolbar .bw-menu-list", "text-align"=>"left"),
    CSS(".bt-output-card", "border"=>"1px solid var(--bw-border)", "border-radius"=>"var(--bw-radius)",
        "background"=>"var(--bw-bg-panel)", "min-width"=>"0"),
    CSS(".bt-output-card .bt-file-toolbar", "border-radius"=>"var(--bw-radius) var(--bw-radius) 0 0"),
    CSS(".bt-tool-native .bt-output-card .bt-media", "box-shadow"=>"none", "border-radius"=>"0 0 var(--bw-radius) var(--bw-radius)"),
    CSS(".bt-tool-native .bt-output-card .bt-media:hover", "transform"=>"none", "box-shadow"=>"none"),
    CSS("@media (max-width: 640px)",
        CSS(".bt-file-toolbar", "gap"=>"var(--bw-space-1)", "padding"=>"var(--bw-space-2)"),
        CSS(".bt-file-toolbar .bt-btn-kbd", "display"=>"none"),
        CSS(".bt-file-toolbar-meta", "display"=>"none")),
    CSS("@media (pointer: coarse)", CSS(".bt-file-toolbar .bw-menu-trigger, .bt-file-toolbar .bt-share-result",
        "min-height"=>"36px", "min-width"=>"36px")),
]
const FileToolbarStyles = Styles(BASE_STYLES, FILE_TOOLBAR_CSS...)

# Also used by script-free markdown share pages, with their shared stylesheet.
file_toolbar_node(w::FileToolbar) = DOM.div(
    DOM.div(w.title;class="bt-file-toolbar-title"),
    DOM.div(w.metadata;class="bt-file-toolbar-meta"),
    DOM.div(w.actions;class="bt-file-toolbar-actions");class="bt-file-toolbar "*w.class)

function Bonito.jsrender(session::Session,w::FileToolbar)
    node=file_toolbar_node(w)
    if w.caption
        Bonito.onload(session,node,js"""root => {
            const card=root.closest('.bt-tool-msg'), header=card?.querySelector('.bt-tool-header');
            if (!card || !header) return;
            const body=root.closest('.bt-tool-body');
            const sync=()=>{
                if (body && !body.contains(root)) { observer.disconnect(); return; }
                const native=card.classList.contains('bt-tool-native');
                if (card.classList.contains('bt-output-framed')!==native) card.classList.toggle('bt-output-framed',native);
                if (!native) return;
                const source=header.querySelector('.bt-tool-title'), title=root.querySelector('.bt-file-toolbar-title');
                if (!source) return;
                if (title.textContent!==source.textContent) title.textContent=source.textContent;
                if (title.title!==source.title) title.title=source.title;
                if (source.dataset.path) {
                    if (title.dataset.path!==source.dataset.path) title.dataset.path=source.dataset.path;
                    if (!title.classList.contains('bt-path-link')) title.classList.add('bt-path-link');
                }
                const meta=root.querySelector('.bt-file-toolbar-meta'), summary=header.querySelector('.bt-tool-summary')?.textContent || '';
                if (meta.textContent!==summary) meta.textContent=summary;
            };
            const observer=new MutationObserver(sync);
            observer.observe(card,{attributes:true,attributeFilter:['class']});
            observer.observe(header,{childList:true,subtree:true,attributes:true,attributeFilter:['title','data-path']});
            if (body) observer.observe(body,{childList:true});
            $(session.on_close).on(()=>observer.disconnect());
            sync();
        }""")
    end
    return Bonito.jsrender(session,DOM.div(FileToolbarStyles,node;class="bt-file-toolbar-slot"))
end
