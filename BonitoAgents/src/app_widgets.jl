# Public composition helpers for plugin panes. They carry the same theme and
# BonitoWidgets controls as the server, including when rendered on their own.
const APP_CARD_STYLES = Styles(
    # Component variants (worker accents, plugin borders) must override these
    # defaults regardless of which stylesheet was mounted first.
    CSS(":where(.bt-app-card)", "background" => "var(--bw-bg-panel)", "color" => "var(--bw-text)",
        "border" => "1px solid var(--bw-border)", "border-radius" => "var(--bw-radius)",
        "box-shadow" => "var(--bw-shadow-sm)"),
    CSS(".bw-btn:disabled", "opacity" => "0.5", "cursor" => "not-allowed"),
)

"""
    AppUIStyles

The server's theme and shared control styles, for plugin-specific layouts using
the public BonitoWidgets `--bw-*` theme variables. Components below include it
automatically. Host theme overrides apply to plugin controls as well.
"""
const AppUIStyles = Styles(APP_THEME, BonitoWidgets.BUTTON_STYLES, APP_CARD_STYLES)

"""
    AppButton(content...; variant=:primary, size=:normal, class="", attributes...)

A server-styled button. `variant` is `:primary`, `:secondary`, `:ghost` or
`:danger`; `size` is `:normal` or `:small`. Other attributes (including reactive
`disabled`, `onclick`, and plugin data attributes) pass through to the button.

```julia
AppButton("Save"; onclick = js"e => \$(saved).notify(true)")
```
"""
function AppButton(content...; variant::Symbol = :primary, size::Symbol = :normal,
                   class::AbstractString = "", attributes...)
    variant in (:primary, :secondary, :ghost, :danger) || throw(ArgumentError("unknown button variant: $variant"))
    size in (:normal, :small) || throw(ArgumentError("unknown button size: $size"))
    classes = join(filter(!isempty, ["bw-btn", variant == :primary ? "" : "bw-btn-$variant", size == :small ? "bw-btn-sm" : "", class]), " ")
    return DOM.button([AppUIStyles, content]; type = "button", class = classes, attributes...)
end

"""
    AppCard(content...; class="", tag=:div, attributes...)

A themed surface using the server's shared border, radius and shadow. Padding
and layout belong to the caller. `tag` may be `:div`, `:section` or `:article`.
"""
function AppCard(content...; class::AbstractString = "", tag::Symbol = :div, attributes...)
    tag in (:div, :section, :article) || throw(ArgumentError("unsupported card tag: $tag"))
    return getproperty(DOM, tag)([AppUIStyles, content]; class = "bt-app-card " * class, attributes...)
end

"""
    AppModal(content::Function, open::Observable{Bool}; title="")

The same BonitoWidgets modal used by the server. Its body is built afresh on
each open and removed on close; Escape, the close button and backdrop dismiss
it. Set `open[]` or notify it from a browser controller to open/close it.

```julia
AppModal(is_open; title = "Add account") do
    DOM.div(account_form())
end
```
"""
function AppModal(content::Function, open::Observable{Bool}; title::AbstractString = "")
    return DOM.div(AppUIStyles, BonitoWidgets.Modal(content, open; title); class = "bt-app-modal")
end
