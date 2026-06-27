const ChatStyles = Bonito.Styles(
    # ── Tokens (shared with the dashboard) ────────────────────────────────────
    CSS(":root",
        "--bt-bg"            => "#fafaf9",
        "--bt-surface"       => "#ffffff",
        "--bt-surface-2"     => "#f8fafc",
        "--bt-border"        => "rgba(15,23,42,0.08)",
        "--bt-border-strong" => "rgba(15,23,42,0.14)",
        "--bt-text"          => "#0f172a",
        "--bt-text-muted"    => "#64748b",
        "--bt-text-faint"    => "#94a3b8",
        "--bt-accent"        => "#3b82f6",
        "--bt-accent-hover"  => "#2563eb",
        "--bt-success"       => "#10b981",
        "--bt-error"         => "#ef4444",
        "--bt-warning"       => "#f59e0b",
        "--bt-shadow-sm"     => "0 1px 2px rgba(15,23,42,0.05)",
        "--bt-shadow-md"     => "0 4px 12px rgba(15,23,42,0.08)",
        "--bt-radius"        => "8px",
        "--bt-radius-sm"     => "6px",
        # ── Spacing scale (4px base) — use instead of ad-hoc px so padding/gap
        #    stay consistent across sidebar / dashboard / chat.
        "--bt-space-1"       => "4px",
        "--bt-space-2"       => "8px",
        "--bt-space-3"       => "12px",
        "--bt-space-4"       => "16px",
        "--bt-space-5"       => "24px",
        "--bt-space-6"       => "32px",
        # ── Type scale.
        "--bt-text-xs"       => "11px",
        "--bt-text-sm"       => "13px",
        "--bt-text-md"       => "14px",
        "--bt-text-lg"       => "16px",
        # ── Status colors — ONE source of truth for every liveness indicator
        #    (sidebar LED, in-chat dot, dashboard dot). Online = idle-healthy,
        #    active = a turn is in flight (pulses), offline = worker down.
        "--bt-status-online"  => "#16a34a",
        "--bt-status-active"  => "#16a34a",
        "--bt-status-offline" => "#dc2626"),

    # ── Reset ────────────────────────────────────────────────────────────────
    CSS("html, body",
        "height" => "100%", "margin" => "0", "padding" => "0",
        "overflow" => "hidden"),

    # ── App shell — flex column that fills its container ────────────────────
    # The chat is always mounted inside the unified shell's `.bt-main` slot
    # (a flex column with defined height). `width/height: 100%` + `min-height: 0`
    # makes us a well-behaved flex child: we fill the slot, and `.bt-messages`
    # below can shrink past content height to enable its internal scroll.
    CSS(".bt-app",
        "width" => "100%", "height" => "100%", "min-height" => "0",
        # position:relative so the absolutely-positioned new-message
        # pill (below) anchors to .bt-app rather than the document.
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "font-family" => "'Inter', system-ui, -apple-system, sans-serif",
        "font-size" => "14px",
        "background" => "var(--bt-bg)",
        "color" => "var(--bt-text)",
        "box-sizing" => "border-box",
        "overscroll-behavior" => "none",
        "-webkit-font-smoothing" => "antialiased"),

    # ── Header ───────────────────────────────────────────────────────────────
    # Outer spans full width (border-bottom looks correct); inner row caps at
    # the same content width as messages/input on desktop.
    # Column: the main title/sync row, plus an optional session-config meta
    # line below it (see `header_meta_line`).
    CSS(".bt-header",
        "display" => "flex", "flex-direction" => "column",
        "justify-content" => "center",
        "padding" => "10px 16px",
        "background" => "var(--bt-surface)",
        "border-bottom" => "1px solid var(--bt-border)",
        "flex-shrink" => "0",
        "min-height" => "44px",
        "box-sizing" => "border-box"),
    CSS(".bt-header-row",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "width" => "100%"),

    # ── Lens search bar (header) ─────────────────────────────────────────────
    # Always visible, directly under the control row.
    CSS(".bt-lens-bar",
        "display" => "flex", "flex-direction" => "column", "gap" => "6px",
        "margin-top" => "8px", "width" => "100%"),
    CSS(".bt-lens-row",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-lens-field",
        "position" => "relative", "flex" => "1 1 auto", "display" => "flex",
        "align-items" => "center", "flex-wrap" => "wrap", "gap" => "5px",
        "padding" => "3px 30px 3px 6px",
        "border" => "1px solid var(--bt-border)", "border-radius" => "8px",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-lens-bar.bt-lens-on .bt-lens-field",
        "border-color" => "var(--bt-accent)",
        "background" => "rgba(59,130,246,0.06)"),
    # The input is now borderless — the .bt-lens-field is the visible box that
    # holds the committed pills + the inline input together.
    CSS("input.bt-lens-input",
        "flex" => "1 1 120px", "min-width" => "120px",
        "padding" => "3px 4px",
        "border" => "none", "background" => "transparent",
        "color" => "var(--bt-text)",
        "font-size" => "12.5px", "box-sizing" => "border-box",
        "font-family" => "inherit"),
    # Committed clause pills.
    CSS(".bt-lens-pills",
        "display" => "inline-flex", "align-items" => "center",
        "flex-wrap" => "wrap", "gap" => "5px"),
    CSS(".bt-lens-pill",
        "display" => "inline-flex", "align-items" => "center", "gap" => "4px",
        "padding" => "2px 4px 2px 8px", "border-radius" => "6px",
        "background" => "rgba(59,130,246,0.16)",
        "border" => "1px solid rgba(59,130,246,0.35)",
        "color" => "var(--bt-text)", "font-size" => "11.5px",
        "font-family" => "ui-monospace, monospace", "cursor" => "pointer",
        "max-width" => "260px", "white-space" => "nowrap"),
    CSS(".bt-lens-pill:hover", "border-color" => "var(--bt-accent)"),
    # Exclude pills read as "remove this" — red-tinted.
    CSS(".bt-lens-pill-ex",
        "background" => "rgba(239,68,68,0.14)",
        "border-color" => "rgba(239,68,68,0.4)"),
    CSS(".bt-lens-pill-sign", "color" => "var(--bt-error)", "font-weight" => "700"),
    CSS(".bt-lens-pill-key", "font-weight" => "600"),
    CSS(".bt-lens-pill-q",
        "color" => "var(--bt-text-muted)", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "max-width" => "130px"),
    CSS(".bt-lens-pill-act",
        "font-size" => "10px", "text-transform" => "uppercase",
        "letter-spacing" => "0.04em", "padding" => "0 5px",
        "border-radius" => "999px", "background" => "var(--bt-accent)",
        "color" => "#fff"),
    CSS(".bt-lens-pill-x",
        "opacity" => "0.55", "padding" => "0 3px", "border-radius" => "4px",
        "font-size" => "9px"),
    CSS(".bt-lens-pill-x:hover", "opacity" => "1", "background" => "rgba(0,0,0,0.18)"),
    # While composing an exclude clause, tint the input box red.
    CSS(".bt-lens-bar.bt-lens-pending-ex input.bt-lens-input::placeholder",
        "color" => "var(--bt-error)"),
    CSS("input.bt-lens-input:focus", "outline" => "none"),
    CSS(".bt-lens-save",
        "position" => "absolute", "right" => "6px",
        "background" => "transparent", "border" => "none",
        "color" => "var(--bt-text-faint)", "cursor" => "pointer",
        "font-size" => "15px", "padding" => "0 2px", "line-height" => "1"),
    CSS(".bt-lens-save:hover", "color" => "var(--bt-accent)"),
    CSS(".bt-lens-go",
        "padding" => "6px 14px", "border" => "none", "border-radius" => "8px",
        "background" => "var(--bt-accent)", "color" => "#fff",
        "font-size" => "12.5px", "cursor" => "pointer", "flex-shrink" => "0"),
    CSS(".bt-lens-go:hover", "background" => "var(--bt-accent-hover)"),
    CSS(".bt-lens-clear",
        "padding" => "6px 10px", "border" => "1px solid var(--bt-border)",
        "border-radius" => "8px", "background" => "var(--bt-surface)",
        "color" => "var(--bt-text-muted)", "cursor" => "pointer",
        "font-size" => "12px", "flex-shrink" => "0"),
    CSS(".bt-lens-clear:hover", "border-color" => "var(--bt-error)",
        "color" => "var(--bt-error)"),
    # Autocomplete dropdown.
    CSS(".bt-lens-autocomplete",
        "position" => "absolute", "top" => "calc(100% + 4px)", "left" => "0",
        "min-width" => "200px", "z-index" => "30",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)", "border-radius" => "8px",
        "box-shadow" => "var(--bt-shadow-md, 0 4px 16px rgba(0,0,0,0.18))",
        "overflow" => "hidden", "padding" => "4px"),
    CSS(".bt-lens-ac-item",
        "display" => "flex", "align-items" => "baseline", "gap" => "8px",
        "padding" => "5px 10px", "border-radius" => "5px",
        "font-size" => "12.5px", "cursor" => "pointer",
        "font-family" => "ui-monospace, monospace", "color" => "var(--bt-text)"),
    CSS(".bt-lens-ac-item.bt-ac-sel, .bt-lens-ac-item:hover",
        "background" => "var(--bt-accent)", "color" => "#fff"),
    CSS(".bt-lens-ac-label", "flex" => "0 0 auto"),
    CSS(".bt-lens-ac-hint",
        "margin-left" => "auto", "font-size" => "10.5px",
        "opacity" => "0.6", "font-family" => "inherit"),
    CSS(".bt-lens-ac-item.bt-ac-sel .bt-lens-ac-hint", "opacity" => "0.85"),
    # Saved-lens chips.
    CSS(".bt-lens-chips",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "6px"),
    CSS(".bt-lens-chip",
        "display" => "inline-flex", "align-items" => "center", "gap" => "5px",
        "padding" => "3px 4px 3px 9px", "border-radius" => "999px",
        "background" => "var(--chip, var(--bt-surface-2))",
        "color" => "#fff", "font-size" => "11px", "cursor" => "pointer",
        "max-width" => "180px"),
    CSS(".bt-lens-chip-label",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-lens-chip-x",
        "opacity" => "0.7", "padding" => "0 4px", "border-radius" => "999px",
        "font-size" => "10px"),
    CSS(".bt-lens-chip-x:hover",
        "opacity" => "1", "background" => "rgba(0,0,0,0.2)"),
    CSS(".bt-header-back",
        "color" => "var(--bt-text)", "text-decoration" => "none",
        "font-size" => "20px", "line-height" => "1",
        "padding" => "4px 10px", "border-radius" => "6px",
        "transition" => "background 80ms, color 80ms",
        "flex-shrink" => "0"),
    CSS(".bt-header-back:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    # Title shrinks to fit but doesn't grow — keeps the Sync button right next
    # to the title rather than pushed to the far edge.
    CSS(".bt-header-title",
        "font-weight" => "600", "font-size" => "14px",
        "min-width" => "0", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "flex" => "0 1 auto"),
    # Inline-editable variant (an <input> over ProjectInfo.title). Reads as
    # plain title text until clicked; hover/focus surface a soft field so the
    # editability is discoverable. Same pattern as the worker-name edit on
    # the dashboard cards. Needs an explicit flex-grow + cap: an input has no
    # intrinsic text width, so without it the field collapses/overflows.
    CSS("input.bt-header-title-edit",
        "appearance" => "none",
        "border" => "none",
        "background" => "transparent",
        "color" => "inherit",
        "font" => "inherit",
        "font-weight" => "600",
        "outline" => "none",
        "padding" => "2px 6px",
        "margin" => "-2px -6px",
        "border-radius" => "var(--bt-radius-sm)",
        "flex" => "1 1 auto",
        "max-width" => "420px",
        "cursor" => "text",
        "transition" => "background 80ms, box-shadow 80ms"),
    CSS("input.bt-header-title-edit:hover",
        "background" => "var(--bt-surface-2)"),
    CSS("input.bt-header-title-edit:focus",
        "background" => "var(--bt-surface-2)",
        "box-shadow" => "inset 0 0 0 1px var(--bt-border-strong)"),
    CSS(".bt-header-cwd",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "color" => "var(--bt-text-muted)", "font-weight" => "400",
        "margin-left" => "6px"),
    # Project-env sub-line under the title row. Muted monospace, single line
    # with ellipsis so a long absolute path never widens the header.
    CSS(".bt-header-env",
        "font-family" => "ui-monospace, monospace", "font-size" => "11px",
        "color" => "var(--bt-text-muted)", "font-weight" => "400",
        "margin-top" => "2px", "max-width" => "100%",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-header-sync",
        "appearance" => "none",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
        "font-size" => "12px", "padding" => "4px 10px",
        "border-radius" => "6px",
        "cursor" => "pointer",
        # Compact: the idle label is just "Sync". While a sync runs, the
        # label switches to a short, COMPACTED progress string (the Julia
        # side truncates it — see `compact_sync_label`); the full per-file
        # message rides on the title attribute. max-width caps the syncing
        # state so the header never reflows wildly; tabular-nums keeps
        # digit columns stable so the counter doesn't dance.
        "max-width" => "220px",
        "text-align" => "left",
        "white-space" => "nowrap",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "font-variant-numeric" => "tabular-nums",
        "transition" => "background 80ms"),
    CSS(".bt-header-sync:hover",
        "background" => "var(--bt-surface-2)"),
    # Header-level restart: visually quieter than Sync (no wide stable
    # min-width — its label only flips between "Restart" and
    # "Restarting…", neither long), but the same chrome so the row reads
    # as a uniform control strip.
    CSS(".bt-header-restart",
        "appearance" => "none",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
        "font-size" => "12px", "padding" => "4px 10px",
        "border-radius" => "6px",
        "cursor" => "pointer",
        "white-space" => "nowrap",
        "transition" => "background 80ms"),
    CSS(".bt-header-restart:hover",
        "background" => "var(--bt-surface-2)"),
    # Session-dead flash: replaces the old session-ended banner. The
    # permanent restart button itself becomes the failure indicator —
    # gentle red pulse on a danger-tinted background so it's hard to
    # miss without being jarring. The title attribute (set in JS via
    # the Observable bridge) carries the actual error text so the user
    # can read it on hover. ~1.4 s loop is slow enough to read as
    # "needs attention" rather than "everything is broken".
    CSS(".bt-header-restart-dead",
        "background" => "#fee2e2",
        "border-color" => "#fca5a5",
        "color" => "#b91c1c",
        "animation" => "bt-restart-pulse 1.4s ease-in-out infinite"),
    CSS(".bt-header-restart-dead:hover",
        "background" => "#fecaca"),
    CSS("@keyframes bt-restart-pulse",
        CSS("0%, 100%", "box-shadow" => "0 0 0 0 rgba(220,38,38,0.0)"),
        CSS("50%",      "box-shadow" => "0 0 0 6px rgba(220,38,38,0.15)")),
    # While a restart is actually running the button shows this "working" state
    # instead of the red dead pulse — so it reads as "restarting…", not "broken,
    # click me", and isn't styled as the clickable failure indicator. `progress`
    # cursor + a gentle opacity breathe; clicks are ignored by the handler guard.
    CSS(".bt-header-restart-busy",
        "cursor" => "progress",
        "animation" => "bt-restart-working 1s ease-in-out infinite"),
    CSS(".bt-header-restart-busy:hover",
        "background" => "var(--bt-surface)"),
    CSS("@keyframes bt-restart-working",
        CSS("0%, 100%", "opacity" => "0.5"),
        CSS("50%",      "opacity" => "0.9")),
    # ── Provider switcher ──────────────────────────────────────────────────
    # Dropdown to switch between Claude Code and MiMo Code. Styled as a
    # compact pill similar to the restart button.
    CSS(".bt-header-provider-select",
        "appearance" => "none",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
        "font-size" => "12px", "padding" => "4px 10px",
        "border-radius" => "6px",
        "cursor" => "pointer",
        "white-space" => "nowrap",
        "transition" => "background 80ms"),
    CSS(".bt-header-provider-select:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-header-provider-select:focus",
        "outline" => "2px solid var(--bt-accent)",
        "outline-offset" => "1px"),
    # Transient provider-switch status ("Switching…"/"switch failed"). Lives in
    # the flexible left area (before the auto-margin), capped + ellipsized so it
    # never reflows the control cluster.
    CSS(".bt-header-status",
        "font-size" => "12px",
        "color" => "var(--bt-text-muted)",
        "white-space" => "nowrap",
        "flex" => "0 0 auto",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "max-width" => "220px"),
    # ── Session-config meta line (model / mode / effort — `header_meta_line`).
    # Plain muted text below the title row; items joined with " · ", full
    # descriptions in the per-item tooltip.
    # Sits inline in the control row (the session-config "model" picks). Shrinks
    # and ellipsizes before the fixed buttons do; pushed to the right by the
    # title's flex-grow.
    CSS(".bt-header-meta",
        "font-size" => "12px",
        "color" => "var(--bt-text-muted)",
        # Sits left (after the title), content-width, growing rightward into the
        # gap before the right-anchored `.bt-header-actions`. Min-width keeps the
        # empty state (during a switch) from collapsing the layout; max-width
        # ellipsizes a very long model name instead of squeezing the title.
        "flex" => "0 1 auto", "min-width" => "0", "max-width" => "260px",
        "white-space" => "nowrap",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    # The right-anchored control cluster (provider switcher · sync · restart).
    # `margin-left:auto` pushes it to the right edge; because the model pill and
    # status text live OUTSIDE it (to its left), their width changes are absorbed
    # by the gap and never move these buttons.
    CSS(".bt-header-actions",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "margin-left" => "auto", "flex" => "0 0 auto"),
    CSS(".bt-header-meta-item",
        "cursor" => "default"),

    # Model picker — a native <select> styled as the meta-item pill. We strip
    # the native chrome (no border / no system background / no arrow gap) so it
    # reads as a clickable text label; only on hover does the box-shadow ring +
    # the down-arrow hint that it's interactive. `currentColor` keeps the
    # arrow matching the muted meta-text color.
    CSS(".bt-header-meta-pick",
        "padding" => "0",                 # the <select> brings its own
        "cursor" => "pointer",
        "border-radius" => "3px",
        "transition" => "background 80ms ease, box-shadow 80ms ease"),
    CSS(".bt-header-meta-pick:hover",
        "background" => "var(--bt-surface-soft, rgba(127,127,127,0.08))",
        "box-shadow" => "0 0 0 1px var(--bt-border, rgba(127,127,127,0.25))"),
    CSS(".bt-header-meta-select",
        "appearance" => "none",
        "-webkit-appearance" => "none",
        "-moz-appearance" => "none",
        "background" => "transparent",
        "border" => "0",
        "outline" => "0",
        "color" => "inherit",
        "font" => "inherit",
        "padding" => "1px 14px 1px 4px",
        "cursor" => "pointer",
        # Tiny down-arrow rendered as an inline SVG background so the pill
        # doesn't depend on a font-glyph being available.
        "background-image" => "url(\"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 6'><path fill='currentColor' d='M0 0l5 6 5-6z'/></svg>\")",
        "background-repeat" => "no-repeat",
        "background-position" => "right 3px center",
        "background-size" => "7px 5px"),
    CSS(".bt-header-meta-select:focus-visible",
        "outline" => "1px solid var(--bt-accent, #3b82f6)",
        "outline-offset" => "1px",
        "border-radius" => "3px"),

    # ── Status dot (online/offline/streaming) ────────────────────────────────
    # Shared liveness dot (chat header, dashboard). Same status palette as the
    # sidebar LED. `vertical-align: middle` keeps it centered against the title
    # text it sits next to (it used to ride high / look detached in the header).
    CSS(".bt-dot",
        "display" => "inline-block",
        "width" => "8px", "height" => "8px",
        "border-radius" => "50%", "flex-shrink" => "0",
        "vertical-align" => "middle"),
    CSS(".bt-dot-online",
        "background" => "var(--bt-status-online)"),
    CSS(".bt-dot-offline", "background" => "var(--bt-status-offline)"),

    # (The old `.bt-banner-error` / `.bt-banner-detail` session-ended
    # banner has been removed: the permanent header restart button is
    # now the failure indicator — see `.bt-header-restart-dead` above
    # for the pulse + danger tint; the error text rides on its title
    # attribute, set reactively from `model.last_error`.)
    CSS(".bt-btn-secondary",
        "background" => "var(--bt-surface)", "color" => "var(--bt-text)",
        "border" => "1px solid var(--bt-border-strong)",
        "padding" => "6px 12px", "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "13px", "cursor" => "pointer"),
    CSS(".bt-btn-secondary:hover",
        "background" => "var(--bt-surface-2)"),

    # ── Messages container ───────────────────────────────────────────────────
    # Fills `.bt-main` (no centered 880px column) — the user complained that a
    # centered messages column left a dead band of empty space between its
    # right scrollbar and the shell border. Individual bubbles still cap their
    # own width (see `.bt-user-msg`/`.bt-agent-msg` `max-width: min(…)`) so a
    # very wide viewport doesn't sprawl any single message.
    # overflow-anchor: NONE — the virtual scroller owns scroll anchoring.
    # With the browser's native anchoring on, message nodes were anchor
    # candidates: every spacer resize / node insert made Chromium adjust
    # scrollTop on its own, concurrently with the scroller's bottom-pin and
    # spacer compensation — two systems correcting the same scroll position
    # is jumpy and makes geometry bugs non-deterministic.
    CSS(".bt-messages",
        "flex" => "1 1 0", "min-height" => "0",
        "overflow-y" => "auto", "overflow-x" => "hidden",
        "-webkit-overflow-scrolling" => "touch",
        "overscroll-behavior-y" => "contain",
        "overflow-anchor" => "none",
        "padding" => "16px",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "10px",
        "width" => "100%",
        "box-sizing" => "border-box"),
    CSS(".bt-spacer-top, .bt-spacer-bottom",
        "flex-shrink" => "0", "overflow-anchor" => "none"),

    # Rubberband for the grab-to-pan handler (bonitoagents.js): when the
    # user drags past either edge, JS accumulates an overscroll distance
    # into `--bt-overscroll` on the container; each direct child of
    # `.bt-messages` mirrors that translateY so the content rubberbands
    # while the container box (and its scrollbar) stay put. Identity
    # `translateY(0)` is the resting state so the rule is always live and
    # paints aren't gated on JS having ever set the var. Native scrolling
    # is untouched — overscroll-behavior-y: contain (above) just stops
    # the bounce from leaking to the parent; rubberband is exclusively
    # the pan handler's affordance.
    # Rubberband translateY, applied ONLY while actively overscrolling
    # (`bt-overscrolling` is toggled by the pan handler's setOverscroll). A
    # non-`none` transform on every child promotes each to its own stacking
    # context and defeats native scroll compositing — so we keep it off for
    # steady-state scrolling and switch it on only for the brief rubberband.
    CSS(".bt-messages.bt-overscrolling > *",
        "transform" => "translateY(var(--bt-overscroll, 0px))"),
    # While the user is panning, the cursor lands as grabbing on any
    # child (text bubbles included): the gesture has hijacked the
    # selection cursor for the duration. Cleared on pointerup so reading
    # cursors snap back without ghost-state.
    CSS(".bt-messages-grabbing, .bt-messages-grabbing *",
        "cursor" => "grabbing !important",
        "user-select" => "none"),

    # ── User message ─────────────────────────────────────────────────────────
    # max-width caps the bubble at a comfortable reading width on wide screens.
    # `flex-shrink: 0` is defensive (see .bt-tool-msg note) — even though
    # this rule has no `overflow` today, future styling shouldn't be able to
    # make message bubbles collapse under spacer pressure.
    CSS(".bt-user-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-end",
        "max-width" => "min(80%, 640px)",
        "background" => "var(--bt-accent)", "color" => "#fff",
        "border-radius" => "12px 12px 2px 12px",
        "padding" => "10px 14px",
        "font-size" => "14px", "line-height" => "1.5",
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "box-shadow" => "var(--bt-shadow-sm)",
        "position" => "relative",
        "transition" => "opacity 160ms ease"),
    # Queued state: the user submitted while a prior turn was still running.
    # Dim the bubble and badge it "queued" until `user_unqueue` promotes it.
    CSS(".bt-user-msg.bt-queued",
        "opacity" => "0.65"),
    CSS(".bt-user-msg.bt-queued::after",
        "content" => "\"queued\"",
        "position" => "absolute",
        "right" => "10px", "bottom" => "-16px",
        "font-size" => "10px",
        "font-weight" => "500",
        "letter-spacing" => "0.04em",
        "color" => "var(--bt-text-faint)",
        "text-transform" => "uppercase"),

    # ── Agent message ────────────────────────────────────────────────────────
    CSS(".bt-agent-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "2px 12px 12px 12px",
        "padding" => "10px 14px",
        "font-size" => "14px", "line-height" => "1.55",
        "word-break" => "break-word",
        "box-shadow" => "var(--bt-shadow-sm)"),

    # While a bubble streams we show the raw text (markdown isn't parsed
    # until finalize). `pre-wrap` keeps the agent's newlines visible —
    # without it `white-space: normal` collapses every `\n` to a space and
    # the whole message renders as one run-on paragraph until finalize.
    CSS(".bt-stream-text",
        "white-space" => "pre-wrap", "word-break" => "break-word"),
    # Streaming cursor blink
    CSS(".bt-stream-text::after",
        "content" => "\"▋\"",
        "animation" => "bt-cursor 0.8s step-end infinite",
        "color" => "var(--bt-accent)",
        "margin-left" => "1px"),
    CSS("@keyframes bt-cursor",
        CSS("0%, 100%", "opacity" => "1"),
        CSS("50%", "opacity" => "0")),

    # ── Thought (extended thinking) ──────────────────────────────────────────
    CSS(".bt-thought-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "border" => "1px dashed var(--bt-border-strong)",
        "border-radius" => "10px",
        "background" => "transparent",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-thought-details", "padding" => "0"),
    CSS(".bt-thought-summary",
        "padding" => "8px 12px",
        "cursor" => "pointer",
        "list-style" => "none",
        "font-size" => "13px",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-thought-summary::-webkit-details-marker", "display" => "none"),
    CSS(".bt-thought-summary::before",
        "content" => "\"▸\"",
        "color" => "var(--bt-text-faint)",
        "transition" => "transform 120ms"),
    CSS("details[open] > .bt-thought-summary::before",
        "transform" => "rotate(90deg)"),
    CSS(".bt-thought-body",
        "padding" => "0 12px 10px 28px",
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "font-size" => "12.5px", "line-height" => "1.5",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-thought-loading, .bt-tool-loading",
        "color" => "var(--bt-text-faint)",
        "font-style" => "italic", "font-size" => "12px",
        "padding" => "4px 0"),

    # ── Tool call card ───────────────────────────────────────────────────────
    # NOTE: `flex-shrink: 0` is load-bearing. `.bt-messages` is a flex column
    # container, and per the CSS Flexbox spec, a flex item with any
    # `overflow` keyword set has its default `min-height` switch from `auto`
    # (content height) to `0`. Combined with the virtual-scroll spacer-top
    # whose height runs into the thousands of px, that lets every tool card
    # shrink down to a 1px slit (border only). Same trap would catch any
    # other bubble that grows an `overflow: hidden`, so we apply the same
    # `flex-shrink: 0` to the other message types defensively below.
    CSS(".bt-tool-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(92%, 800px)",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "13px",
        "box-shadow" => "var(--bt-shadow-sm)",
        "overflow" => "hidden",
        # Positioning context for the absolute `.bt-tool-fullwidth` button that
        # floats at the bubble's right-edge center.
        "position" => "relative",
        # Transition so flipping the wide toggle animates smoothly rather than
        # snapping in at a different width and tearing the layout.
        "transition" => "max-width 160ms ease, align-self 160ms ease"),
    # Full-chat-width toggle. Spans the entire message column so wide content
    # (diffs / tables / `bt_show_app` embeds) has the room it needs. Flipped by
    # the .bt-tool-wide button in the tool header.
    CSS(".bt-tool-msg.bt-tool-wide-active",
        "align-self" => "stretch",
        "max-width" => "100%"),
    # Detach button in the tool header (rendered only for bonito_app tools).
    # ⤢ is the conventional "open in a window" glyph; clicking pops the embed
    # into the floating window. Small, neutral, sits at the right of the header.
    CSS(".bt-tool-detach",
        "margin-left" => "4px",
        "background" => "transparent",
        "border" => "none",
        "padding" => "2px 6px",
        "cursor" => "pointer",
        "color" => "var(--bt-text-faint)",
        "font-size" => "13px",
        "line-height" => "1",
        "border-radius" => "var(--bt-radius-sm)",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-tool-detach:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    # Full-chat-width toggle — a slim, quiet header button (same chrome as the
    # ⤢ detach button), NOT an overlay floating over the body: an absolutely
    # positioned button covered the actual app/diff content and looked bulky.
    # Hidden by default; revealed only while the tool body is expanded —
    # there's nothing to widen on a collapsed header.
    CSS(".bt-tool-fullwidth",
        "display" => "none",
        "background" => "transparent",
        "border" => "none",
        "padding" => "2px 6px",
        "cursor" => "pointer",
        "color" => "var(--bt-text-faint)",
        "font-size" => "13px", "line-height" => "1",
        "border-radius" => "var(--bt-radius-sm)",
        "flex-shrink" => "0",
        "user-select" => "none",
        "transition" => "background 80ms, color 80ms"),
    CSS(".bt-tool-fullwidth:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    # Reveal the full-width toggle only while the body is expanded
    # (Collapsable flips `data-expanded` on the header it lives in).
    CSS(".bt-tool-header[data-expanded=\"true\"] .bt-tool-fullwidth",
        "display" => "inline-flex"),
    # NOTE: deliberately NO `user-select: none` here — every piece of text in
    # the app should be selectable + copyable (file paths especially). The
    # browser treats a drag-select as a drag (not a click), so the
    # expand-on-click handler still fires only on real clicks.
    CSS(".bt-tool-header",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "8px 12px",
        "cursor" => "pointer",
        "transition" => "background 80ms"),
    # The title / summary / server badge carry the actual content the user
    # wants to grab — show a text cursor there so the affordance is obvious.
    CSS(".bt-tool-title, .bt-tool-summary, .bt-tool-server",
        "cursor" => "text"),
    CSS(".bt-tool-header:hover",
        "background" => "var(--bt-surface-2)"),
    # The expand/collapse glyph (`▶` / `▼`) is swapped directly in JS
    # (wireToolToggle). No `transform: rotate()` here — rotating the
    # already-swapped `▼` produced a sideways arrow.
    CSS(".bt-tool-toggle",
        "color" => "var(--bt-text-faint)", "font-size" => "11px",
        "flex-shrink" => "0",
        # The disclosure glyph is chrome, not content — keep it out of
        # drag-selections (the header text itself IS selectable).
        "user-select" => "none",
        # While EXPANDED this glyph is the ONLY collapse control (see
        # Collapsable's click handler) — give it a real hit area.
        "padding" => "6px 8px",
        "margin" => "-6px -2px -6px -8px",
        "border-radius" => "var(--bt-radius-sm)"),
    CSS(".bt-tool-header[data-expanded=\"true\"] .bt-tool-toggle:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    CSS(".bt-tool-kind",
        "font-size" => "13px", "flex-shrink" => "0"),
    # MCP server badge — dim pill before the tool name (e.g. "btworker").
    CSS(".bt-tool-server",
        "flex-shrink" => "0",
        "font-size" => "10.5px", "font-weight" => "600",
        "letter-spacing" => "0.02em",
        "color" => "var(--bt-text-faint)",
        "background" => "var(--bt-surface-2)",
        "border-radius" => "999px",
        "padding" => "1px 7px"),
    CSS(".bt-tool-title",
        "flex" => "1 1 auto", "min-width" => "0",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-tool-summary",
        "color" => "var(--bt-text-muted)", "font-size" => "11.5px",
        "flex-shrink" => "0",
        "white-space" => "nowrap"),

    # Tool status — slim pill, harmonized with dashboard
    CSS(".bt-tool-status",
        "display" => "inline-flex", "align-items" => "center",
        "gap" => "4px",
        "font-size" => "11px", "font-weight" => "500",
        "padding" => "1px 8px",
        "border-radius" => "999px",
        "white-space" => "nowrap", "flex-shrink" => "0"),
    CSS(".bt-status-pending",
        "background" => "rgba(245,158,11,0.12)", "color" => "#92400e"),
    CSS(".bt-status-in_progress",
        "background" => "rgba(59,130,246,0.12)", "color" => "#1d4ed8"),
    CSS(".bt-status-completed",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-status-failed",
        "background" => "rgba(239,68,68,0.12)", "color" => "#b91c1c"),

    # ── Live tool/todo pulse ─────────────────────────────────────────────────
    # Subtle box-shadow oscillation while a tool is mid-flight. Two layers:
    # the rest-state shadow keeps `.bt-tool-msg`'s normal lift, the keyframes
    # add a softly-pulsing ring on top. `prefers-reduced-motion` disables it
    # for users who don't want movement.
    CSS("@keyframes bt-pulse-glow",
        CSS("0%, 100%",
            "box-shadow" => "var(--bt-shadow-sm), 0 0 0 0 rgba(59,130,246,0.35)"),
        CSS("50%",
            "box-shadow" => "var(--bt-shadow-sm), 0 0 0 6px rgba(59,130,246,0.00)")),
    CSS(".bt-tool-msg.bt-tool-live, .bt-plan-msg.bt-plan-live",
        "animation" => "bt-pulse-glow 1.6s ease-in-out infinite",
        "border-color" => "rgba(59,130,246,0.42)"),
    CSS("@media (prefers-reduced-motion: reduce)",
        CSS(".bt-tool-msg.bt-tool-live, .bt-plan-msg.bt-plan-live",
            "animation" => "none")),

    # ── Tool elapsed timer ───────────────────────────────────────────────────
    # Small monospace span next to the status pill. JS sets `data-tool-started`
    # on the bubble; a 1-second ticker writes `data-tool-elapsed-ms` and only
    # renders text once we cross > 1s (so a fast Read never flashes "0s").
    CSS(".bt-tool-timer",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "10.5px",
        "color" => "var(--bt-text-muted)",
        "flex-shrink" => "0",
        "min-width" => "20px",
        "text-align" => "right"),
    CSS(".bt-tool-msg.bt-tool-live .bt-tool-timer",
        "color" => "var(--bt-accent)"),

    # ── Taskbar ──────────────────────────────────────────────────────────────
    # Floats over the messages area, anchored top-left of the chat panel.
    # `position: absolute` (NOT fixed and NOT sticky-in-scroll): it stays put
    # relative to `.bt-app` while the messages scroll underneath, but doesn't
    # poke out of the chat panel when other panels (sidebar, plotpane) resize.
    # No background or border on the container — each slot is a free-floating
    # capsule with its own surface, so multiple slots read as a stack rather
    # than a bordered widget.
    # Positioning context shared by the messages area and the floating
    # taskbar: the wrapper takes over the messages' flex role so the taskbar
    # anchors below the (variable-height) header, over the messages.
    CSS(".bt-messages-wrap",
        "position" => "relative",
        "flex" => "1 1 0", "min-height" => "0",
        "display" => "flex", "flex-direction" => "column"),
    CSS(".bt-taskbar",
        "position" => "absolute",
        "top" => "8px", "left" => "8px",
        "z-index" => "6",
        "pointer-events" => "none",   # slots re-enable so we don't catch the messages scroll
        "max-width" => "280px"),
    CSS(".bt-taskbar-slots",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "6px"),
    # One slot per live tool. Capsule shape, accent-tinted; click jumps back
    # to the source bubble (virtual-scroller index jump in bonitoagents.js).
    CSS(".bt-taskbar-slot",
        "pointer-events" => "auto",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "4px 6px 4px 10px",
        "border-radius" => "999px",
        "background" => "var(--bt-surface)",
        "border" => "1px solid rgba(59,130,246,0.42)",
        "box-shadow" => "var(--bt-shadow-sm)",
        "font-size" => "11.5px",
        "color" => "var(--bt-text)",
        "cursor" => "pointer",
        "max-width" => "100%",
        "white-space" => "nowrap",
        "transition" => "background 80ms, transform 80ms"),
    CSS(".bt-taskbar-slot:hover",
        "background" => "var(--bt-surface-2)",
        "transform" => "translateX(2px)"),
    CSS(".bt-taskbar-slot-icon",
        "flex-shrink" => "0", "font-size" => "13px"),
    CSS(".bt-taskbar-slot-label",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis"),
    CSS(".bt-taskbar-slot-timer",
        "flex-shrink" => "0",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "10.5px",
        "color" => "var(--bt-accent)"),

    # The live-todo panel: a left-aligned CARD, not a capsule — selector
    # carries both classes so these rules outweigh the base slot rules
    # regardless of order. Every item gets a ✓/▸/○ marker; finished entries
    # crossed out, the active one accented.
    CSS(".bt-taskbar-slot.bt-taskbar-todo",
        "flex-direction" => "column",
        "align-items" => "stretch",
        "text-align" => "left",
        "gap" => "4px",
        "border-radius" => "10px",
        "padding" => "7px 10px",
        "min-width" => "210px",
        "cursor" => "default"),
    CSS(".bt-taskbar-slot.bt-taskbar-todo:hover",
        "background" => "var(--bt-surface)",
        "transform" => "none"),
    CSS(".bt-taskbar-todo-head",
        "display" => "flex", "align-items" => "center", "gap" => "6px",
        "font-weight" => "600"),
    CSS(".bt-taskbar-todo-item",
        "font-size" => "11.5px",
        "color" => "var(--bt-text-muted)",
        "white-space" => "nowrap",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-taskbar-todo-item::before",
        "content" => "'○ '",
        "display" => "inline-block",
        "width" => "15px",
        "color" => "var(--bt-text-faint)"),
    CSS(".bt-taskbar-todo-item.bt-todo-active",
        "color" => "var(--bt-text)",
        "font-weight" => "600"),
    CSS(".bt-taskbar-todo-item.bt-todo-active::before",
        "content" => "'▸ '",
        "color" => "var(--bt-accent)"),
    CSS(".bt-taskbar-todo-item.bt-todo-done",
        "text-decoration" => "line-through",
        "opacity" => "0.55"),
    CSS(".bt-taskbar-todo-item.bt-todo-done::before",
        "content" => "'✓ '",
        "color" => "var(--bt-success, #16a34a)"),

    # Mini stop button — the composer stop button's little sibling, shared
    # by taskbar slots and live tool pills: bordered circle, red rounded
    # square drawn via ::before. ALWAYS visible (no hover reveal — a stop
    # affordance you have to hunt for is not an affordance).
    CSS(".bt-stop-mini",
        "display" => "inline-flex",
        "align-items" => "center", "justify-content" => "center",
        "width" => "20px", "height" => "20px",
        "box-sizing" => "border-box",
        "flex-shrink" => "0",
        "padding" => "0",
        "border-radius" => "50%",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border-strong)",
        "cursor" => "pointer",
        "transition" => "background 120ms, border-color 120ms"),
    CSS(".bt-stop-mini::before",
        "content" => "''",
        "width" => "8px", "height" => "8px",
        "border-radius" => "2px",
        "background" => "var(--bt-error)"),
    CSS(".bt-stop-mini:hover",
        "background" => "rgba(239,68,68,0.08)",
        "border-color" => "var(--bt-error)"),

    # ── Eval extras (bt_julia_eval family) ──────────────────────────────────
    # Timeout badge: small mono hint next to the timer so the soft-checkpoint
    # cadence is visible at a glance.
    CSS(".bt-tool-timeout",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "10.5px",
        "color" => "var(--bt-text-faint)",
        "flex-shrink" => "0",
        "white-space" => "nowrap"),
    # Per-pill stop (shares .bt-stop-mini for the look). Hidden until the
    # pill is live — stopping a finished tool is meaningless.
    CSS(".bt-tool-stop",
        "display" => "none",
        "user-select" => "none"),
    CSS(".bt-tool-msg.bt-tool-live .bt-tool-stop",
        "display" => "inline-flex"),
    # File-path links — tool titles with a file, diff headers, search hits,
    # path-looking code spans in agent messages. Quiet dotted underline as
    # the standing affordance; full link treatment on hover. One delegated
    # listener in bonitoagents.js opens them in the plotpane editor.
    CSS(".bt-path-link",
        "cursor" => "pointer",
        "text-decoration" => "underline dotted",
        "text-decoration-color" => "var(--bt-text-faint)",
        "text-underline-offset" => "3px"),
    CSS(".bt-path-link:hover",
        "color" => "var(--bt-accent)",
        "text-decoration" => "underline",
        "text-decoration-color" => "var(--bt-accent)"),

    # ── Plotpane file editor ─────────────────────────────────────────────────
    # Editable Monaco over a project file, mounted into #bt-plotpane-mount by
    # `EditFileCommand`. Fills the pane; the header carries the path, a save
    # status line, and the Save button.
    CSS(".bt-file-editor",
        "display" => "flex", "flex-direction" => "column",
        "height" => "100%", "min-height" => "0"),
    CSS(".bt-file-editor-header",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "padding" => "6px 10px",
        "border-bottom" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface-2)",
        "flex-shrink" => "0"),
    CSS(".bt-file-editor-path",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11.5px",
        "color" => "var(--bt-text-muted)",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap",
        # Path truncates from the LEFT so the filename (the part that
        # matters) stays visible.
        "direction" => "rtl", "text-align" => "left"),
    CSS(".bt-file-editor-status",
        "font-size" => "11px",
        "color" => "var(--bt-text-faint)",
        "flex-shrink" => "0",
        "white-space" => "nowrap"),
    CSS(".bt-file-editor-body",
        "flex" => "1 1 auto", "min-height" => "0",
        "overflow" => "hidden"),
    # The Monaco wrapper chain must pass full height down to the editor div.
    CSS(".bt-file-editor-body > div, .bt-file-editor-body .monaco-editor-div",
        "height" => "100%", "min-height" => "0"),
    # Live code preview: the code a running bt_julia_eval is executing,
    # painted under the header BEFORE any result exists. Compact by default
    # (capped height + bottom fade), the ⌄ toggle grows it — same
    # small-preview → enlarge interaction as the diff view. Removed when the
    # eval completes (the body's Monaco "Code" section takes over).
    CSS(".bt-eval-preview",
        "position" => "relative",
        "border-top" => "1px solid var(--bt-border)",
        "background" => "#0f172a",
        "max-height" => "132px",
        "overflow" => "hidden"),
    CSS(".bt-eval-preview pre",
        "margin" => "0",
        "padding" => "8px 12px",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "12px", "line-height" => "1.5",
        "color" => "#e2e8f0",
        "white-space" => "pre-wrap", "word-break" => "break-word"),
    # Bottom fade hints that the preview is clipped; gone when enlarged.
    CSS(".bt-eval-preview::after",
        "content" => "\"\"",
        "position" => "absolute",
        "left" => "0", "right" => "0", "bottom" => "0",
        "height" => "28px",
        "pointer-events" => "none",
        "background" => "linear-gradient(to bottom, rgba(15,23,42,0), rgba(15,23,42,0.92))"),
    CSS(".bt-eval-preview.bt-eval-preview-full",
        "max-height" => "600px",
        "overflow-y" => "auto"),
    CSS(".bt-eval-preview.bt-eval-preview-full::after",
        "display" => "none"),
    CSS(".bt-eval-preview-toggle",
        "position" => "absolute",
        "right" => "6px", "bottom" => "4px",
        "z-index" => "2",
        "background" => "rgba(255,255,255,0.08)",
        "border" => "1px solid rgba(255,255,255,0.15)",
        "border-radius" => "var(--bt-radius-sm)",
        "color" => "#e2e8f0",
        "font-size" => "12px", "line-height" => "1",
        "padding" => "2px 8px",
        "cursor" => "pointer",
        "user-select" => "none",
        "transition" => "background 80ms"),
    CSS(".bt-eval-preview-toggle:hover",
        "background" => "rgba(255,255,255,0.18)"),

    CSS(".bt-tool-body",
        "padding" => "0 12px 10px",
        "border-top" => "1px solid var(--bt-border)"),
    # A collapsed tool keeps an EMPTY `.bt-tool-body` placeholder (the body is
    # only rendered into it on expand). Without this it still drew its border-top
    # + bottom padding — a stray ~11px box under every collapsed tool header.
    # Zero it out until it actually has content.
    CSS(".bt-tool-body:empty",
        "padding" => "0", "border-top" => "none"),
    CSS(".bt-tool-empty",
        "padding" => "8px 0",
        "color" => "var(--bt-text-faint)",
        "font-style" => "italic", "font-size" => "12px"),

    # Media (bt_show / Read image & video) + click-to-enlarge lightbox. The wrap
    # is the hover target for the ⤢ button; the fullscreen overlay holds a clone
    # of the media and closes on backdrop click or Esc.
    CSS(".bt-media-wrap",
        "position" => "relative", "display" => "inline-block", "max-width" => "100%"),
    CSS(".bt-media-enlarge",
        "position" => "absolute", "top" => "6px", "right" => "6px",
        "appearance" => "none", "border" => "none",
        "background" => "rgba(0,0,0,0.55)", "color" => "#fff",
        "font-size" => "14px", "line-height" => "1",
        "padding" => "4px 7px", "border-radius" => "6px",
        "cursor" => "zoom-in", "opacity" => "0", "transition" => "opacity 80ms"),
    CSS(".bt-media-wrap:hover .bt-media-enlarge", "opacity" => "1"),
    CSS(".bt-lightbox-overlay",
        "position" => "fixed", "inset" => "0", "z-index" => "9999",
        "background" => "rgba(0,0,0,0.85)", "cursor" => "zoom-out",
        "display" => "flex", "align-items" => "center", "justify-content" => "center"),
    CSS(".bt-lightbox-media",
        "max-width" => "95vw", "max-height" => "95vh",
        "box-shadow" => "0 8px 40px rgba(0,0,0,0.6)", "cursor" => "default"),
    CSS(".bt-tool-md",
        "font-size" => "13px", "line-height" => "1.5",
        "padding-top" => "8px"),

    # Eval-section blocks (BonitoMCP bt_julia_eval output): a tiny uppercase
    # label (STDOUT / RESULT / ERROR) above the Monaco-rendered body of each
    # section, so the input code, captured output, and return value are
    # visually distinct in the tool body.
    CSS(".bt-section-label",
        "font-size" => "10.5px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-faint)",
        "margin" => "12px 0 4px"),
    CSS(".bt-eval-section + .bt-eval-section",
        "margin-top" => "4px"),
    CSS(".bt-eval-section:first-child .bt-section-label",
        "margin-top" => "8px"),

    # Tool-body sub-section collapsibles (`<details>`). Used by bt_julia_eval
    # bodies to split Code / Output into two independently foldable blocks.
    # The disclosure marker is a `::before` glyph swapped on `[open]` — a
    # content swap, never a `transform: rotate()` (that compounds badly and
    # is unreliable in the offscreen renderer; see the tool-toggle fix).
    CSS(".bt-eval-body",
        "display" => "flex", "flex-direction" => "column", "gap" => "6px",
        "padding-top" => "4px"),
    CSS(".bt-subsection",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "overflow" => "hidden"),
    CSS(".bt-subsection-summary",
        "display" => "flex", "align-items" => "baseline", "gap" => "8px",
        "padding" => "6px 10px",
        "cursor" => "pointer",
        "list-style" => "none",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-subsection-summary::-webkit-details-marker", "display" => "none"),
    CSS(".bt-subsection-summary::before",
        "content" => "\"▸\"",
        "color" => "var(--bt-text-faint)", "font-size" => "10px",
        "flex-shrink" => "0"),
    CSS("details.bt-subsection[open] > .bt-subsection-summary::before",
        "content" => "\"▾\""),
    CSS(".bt-subsection-summary:hover",
        "background" => "var(--bt-surface)"),
    CSS(".bt-subsection-label",
        "font-size" => "11px", "font-weight" => "600",
        "letter-spacing" => "0.04em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-muted)", "flex-shrink" => "0"),
    CSS(".bt-subsection-preview",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "11.5px",
        "color" => "var(--bt-text-faint)",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap", "min-width" => "0"),
    CSS(".bt-subsection-body",
        "padding" => "8px 10px"),

    # Console block — wraps a `Bonito.RichText` terminal pane (ANSI → styled
    # HTML). Captured stdout / stderr / error backtraces render here instead
    # of in a Monaco editor: lighter, ANSI-aware, scrolls on overflow.
    CSS(".bt-console",
        "background" => "var(--bt-surface-2)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "8px 10px",
        "max-height" => "360px",
        "overflow" => "auto"),
    CSS(".bt-console .terminal-output",
        "font-family" => "ui-monospace, SFMono-Regular, Menlo, monospace",
        "font-size" => "12px", "line-height" => "1.5",
        "margin" => "0"),

    # ── Edit-tool body container ─────────────────────────────────────────────
    # The body IS the diff preview now — a single (or multi-) Monaco
    # DiffEditor. Size is driven by Monaco's own height API
    # (`MonacoDiffEditor.setMaxHeight`), not by an outer CSS clip. The
    # container just gives it room and a subtle top border so it visually
    # belongs to its header.
    CSS(".bt-edit-tool-body",
        "border-top" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)"),

    # ── Diff blocks (multi-edit) ─────────────────────────────────────────────
    # Single-diff body just shows the editor; multi-edit bodies stack diffs
    # with subtle separators + monospace path headers so you can tell which
    # file each chunk belongs to.
    CSS(".bt-diff-block", "padding-top" => "8px"),
    CSS(".bt-multi-diff .bt-diff-block + .bt-diff-block",
        "margin-top" => "12px",
        "border-top" => "1px solid var(--bt-border)",
        "padding-top" => "12px"),
    CSS(".bt-diff-header",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11px",
        "color" => "var(--bt-text-muted)",
        "padding" => "2px 0 6px",
        "word-break" => "break-all"),

    # ── Search results ───────────────────────────────────────────────────────
    CSS(".bt-search-results",
        "padding" => "8px 0",
        "font-size" => "12px",
        "max-height" => "400px",
        "overflow-y" => "auto"),
    CSS(".bt-search-row",
        "padding" => "3px 0",
        "display" => "flex", "align-items" => "baseline", "gap" => "4px",
        "min-width" => "0"),
    CSS(".bt-search-path",
        "color" => "var(--bt-accent)", "font-weight" => "600",
        "font-family" => "ui-monospace, monospace",
        "flex-shrink" => "0"),
    CSS(".bt-search-line",
        "color" => "var(--bt-text-muted)",
        "font-family" => "ui-monospace, monospace",
        "flex-shrink" => "0"),
    CSS(".bt-search-snippet",
        "color" => "var(--bt-text)",
        "background" => "none", "padding" => "0",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden",
        "white-space" => "nowrap",
        "text-overflow" => "ellipsis"),
    CSS(".bt-search-raw",
        "color" => "var(--bt-text-muted)",
        "font-family" => "ui-monospace, monospace", "font-size" => "11px",
        "padding" => "2px 0",
        "white-space" => "pre-wrap"),

    # ── Plan ─────────────────────────────────────────────────────────────────
    CSS(".bt-plan-msg",
        "align-self" => "flex-start",
        "max-width" => "min(88%, 760px)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-surface)",
        "padding" => "10px 14px",
        "font-size" => "13px",
        "box-shadow" => "var(--bt-shadow-sm)"),
    CSS(".bt-plan-entry",
        "display" => "flex", "align-items" => "flex-start",
        "gap" => "8px", "padding" => "3px 0",
        "color" => "var(--bt-text)"),
    CSS(".bt-plan-status",
        "width" => "16px", "flex-shrink" => "0",
        "text-align" => "center",
        "color" => "var(--bt-text-muted)",
        "font-weight" => "600"),

    # ── Compact-summary separator ────────────────────────────────────────────
    # `/compact` boundary — rendered as a centered, muted, narrower block with
    # subtle horizontal rules on each side so it visually reads "session
    # continued here." Not a bubble: no alignment, no border, no shadow.
    CSS(".bt-summary-msg",
        "align-self" => "center",
        "max-width" => "min(80%, 720px)",
        "margin" => "8px 0",
        "padding" => "10px 18px",
        "text-align" => "center",
        "color" => "var(--bt-text-muted)",
        "font-size" => "12.5px",
        "font-style" => "italic",
        "border-top" => "1px solid var(--bt-border)",
        "border-bottom" => "1px solid var(--bt-border)"),
    CSS(".bt-summary-msg .bt-summary-body",
        "display" => "block",
        # Tighten the markdown render so the centered block reads like a
        # caption, not a wall of body text.
        "line-height" => "1.5"),
    CSS(".bt-summary-msg .bt-summary-body > *:first-child", "margin-top" => "0"),
    CSS(".bt-summary-msg .bt-summary-body > *:last-child",  "margin-bottom" => "0"),

    # ── Markdown inside agent bubble ─────────────────────────────────────────
    CSS(".bt-agent-msg .markdown-body, .bt-agent-msg .markdown",
        "background" => "none", "border" => "none", "padding" => "0",
        "font-size" => "inherit", "font-family" => "inherit",
        "color" => "inherit", "line-height" => "1.55"),
    CSS(".bt-agent-msg .markdown-body > *:first-child, .bt-agent-msg .markdown > *:first-child",
        "margin-top" => "0"),
    CSS(".bt-agent-msg .markdown-body > *:last-child, .bt-agent-msg .markdown > *:last-child",
        "margin-bottom" => "0"),
    # The doubled `.bt-agent-msg .markdown-body …` arms are deliberate: they
    # out-rank Bonito's markdown.css (`.markdown-body pre`, specificity 0,1,1)
    # regardless of stylesheet order. Without them, markdown.css's GitHub
    # light-gray pre background (#f6f8fa) could win the tie while our light
    # `color` (meant for the dark block) still applied → near-invisible code
    # ("opacity overlay" bug).
    CSS(".bt-agent-msg pre, .bt-agent-msg .markdown-body pre",
        "background" => "#0f172a", "color" => "#e2e8f0",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "10px 14px",
        "overflow-x" => "auto",
        "font-size" => "12px", "line-height" => "1.5",
        "margin" => "8px 0"),
    CSS(".bt-agent-msg code, .bt-agent-msg .markdown-body code",
        "background" => "rgba(15,23,42,0.06)",
        "border-radius" => "3px",
        "padding" => "1px 5px",
        "font-size" => "12.5px",
        "font-family" => "ui-monospace, monospace"),
    CSS(".bt-agent-msg pre code, .bt-agent-msg .markdown-body pre code",
        "background" => "none", "padding" => "0",
        "color" => "inherit"),

    # Overscroll tail — empty space below the last message the user can
    # scroll into (sized to ~30% of the pane by `_sizeTail`). All "bottom"
    # math (atBottom / scrollToBottom / pins) targets the CONTENT bottom,
    # treating the tail as beyond-the-end.
    CSS(".bt-messages-tail",
        "flex-shrink" => "0", "overflow-anchor" => "none"),

    # Off-screen measuring host (`_measureNodes`): prefetched message nodes
    # are laid out here — same width as the messages content box — to get
    # real heights before they're ever rendered. Hidden but NOT display:none
    # (children must lay out); zero own height so it never affects the page.
    # Same formatting context as `.bt-messages` (flex column, same gap):
    # bubbles are flex items there (`align-self` ⇒ fit-content width); in a
    # plain block host they'd be measured at fill-width instead. Heights
    # mostly coincide thanks to the max-width caps, but the contexts must
    # match so off-screen measurements can never diverge from the live layout.
    CSS(".bt-measure",
        "position" => "absolute", "left" => "0", "top" => "0",
        "height" => "0", "overflow" => "hidden",
        "visibility" => "hidden",
        "pointer-events" => "none",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "10px",
        "z-index" => "-1"),

    # (The per-chat mount curtain used to live here — the dashboard's load
    # overlay now covers the pane until settle; see `chat_waiting_view` in
    # sidebar.jl and `_startSettle` in bonitoagents.js.)

    # ── Busy indicator ───────────────────────────────────────────────────────
    # Lives inside `.bt-messages` (between the bottom spacer and the
    # overscroll tail) so it shows directly under the last message. The
    # container already pads 16px, so no own horizontal padding; opted out
    # of scroll anchoring like the spacers/tail (the chase owns scrollTop).
    # margin-top -10px cancels the flex row gap that precedes each of the
    # three indicator children (zero-height or not, every flex item costs a
    # gap slot — three indicators after the bottom spacer would push the
    # visible one 30px under the last message). Safe: indicators are plain
    # content the virtual-scroll height math never tracks.
    CSS(".bt-busy",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "overflow-anchor" => "none", "margin-top" => "-10px",
        "display" => "flex", "gap" => "4px", "align-items" => "center",
        "padding" => "0",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-busy.bt-busy-active",
        "height" => "28px", "padding" => "4px 0"),
    # While a thought is streaming, the "reasoning…" line is the liveness
    # indicator — showing the dots too is redundant. The suppress class is
    # toggled from `onThinking` (bonitoagents.js); declared AFTER the active
    # rule so the tie at equal specificity resolves to suppressed.
    CSS(".bt-busy.bt-busy-suppressed",
        "height" => "0", "padding" => "0"),
    CSS(".bt-busy-dot",
        "width" => "7px", "height" => "7px", "border-radius" => "50%",
        "background" => "var(--bt-accent)",
        "animation" => "bt-pulse 1.2s ease-in-out infinite"),
    CSS(".bt-busy-dot:nth-child(2)", "animation-delay" => "0.2s"),
    CSS(".bt-busy-dot:nth-child(3)", "animation-delay" => "0.4s"),
    CSS("@keyframes bt-pulse",
        CSS("0%, 100%", "opacity" => "0.3", "transform" => "scale(0.8)"),
        CSS("50%",      "opacity" => "1",   "transform" => "scale(1.2)")),

    # ── Idle "waiting" indicator ─────────────────────────────────────────────
    # Visible when the busy dots are NOT (keyed off `.bt-busy`'s class via
    # the adjacent-sibling rule — busy_start/busy_end flips and the
    # server-rendered remount class drive both elements in lockstep) AND
    # the chat has agent replies on display: `bt-waiting-on` is toggled by
    # `_updateWaiting` in bonitoagents.js — set once an agent message exists
    # and the Agent filter shows them. An empty chat (nothing asked yet) or
    # a filtered-out agent stream gets no dangling "waiting" line. Same
    # placement rules as `.bt-busy` above (inside `.bt-messages`).
    CSS(".bt-waiting",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "overflow-anchor" => "none", "margin-top" => "-10px",
        "display" => "flex", "align-items" => "center",
        "padding" => "0", "font-size" => "12.5px", "font-style" => "italic",
        "color" => "var(--bt-text-muted)",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-busy:not(.bt-busy-active) + .bt-waiting.bt-waiting-on",
        "height" => "22px", "padding" => "2px 0"),

    # ── Transient "reasoning…" indicator ──────────────────────────────────────
    # Shown for the lifetime of an agent thought (most are redacted/empty, so
    # this is usually the only visible trace of the model thinking). Collapsed
    # to zero height until `.bt-thinking-active` is toggled by the JS.
    # Same placement rules as `.bt-busy` above (inside `.bt-messages`).
    CSS(".bt-thinking",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "overflow-anchor" => "none", "margin-top" => "-10px",
        "display" => "flex", "align-items" => "center",
        "padding" => "0", "font-size" => "12.5px", "font-style" => "italic",
        "color" => "var(--bt-text-muted)",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-thinking.bt-thinking-active",
        "height" => "22px", "padding" => "2px 0"),
    # Running chunk count tacked onto the reasoning indicator. Tabular figures
    # so the width doesn't jitter as the number climbs; empty until the first
    # chunk lands (no leading gap when there's nothing to show).
    CSS(".bt-thinking-count",
        "margin-left" => "6px", "font-style" => "normal",
        "font-variant-numeric" => "tabular-nums",
        "color" => "var(--bt-text-faint)"),
    CSS(".bt-thinking-count:empty", "margin-left" => "0"),
    CSS(".bt-collapsable-loading",
        "color" => "var(--bt-text-faint)",
        "font-style" => "italic", "font-size" => "12px",
        "padding" => "4px 0"),

    # ── Permission / question card ───────────────────────────────────────────
    # Interactive card for `session/request_permission` (AskUserQuestion, plan
    # approval, …): the question + one real button per option. Plain scroll
    # content under the last message (see onPermission in bonitoagents.js).
    CSS(".bt-permission-card",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-accent)",
        "border-radius" => "var(--bt-radius)",
        "padding" => "12px 14px",
        "box-shadow" => "var(--bt-shadow-md)",
        "display" => "flex", "flex-direction" => "column", "gap" => "10px"),
    CSS(".bt-permission-question",
        "font-size" => "14px", "line-height" => "1.5",
        "font-weight" => "500",
        "color" => "var(--bt-text)"),
    CSS(".bt-permission-options",
        "display" => "flex", "flex-wrap" => "wrap", "gap" => "8px"),
    CSS(".bt-permission-btn",
        "appearance" => "none",
        "border" => "1px solid var(--bt-border-strong)",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
        "font-size" => "13px", "font-weight" => "500",
        "padding" => "6px 14px",
        "border-radius" => "999px",
        "cursor" => "pointer",
        "transition" => "background 80ms, border-color 80ms, color 80ms"),
    CSS(".bt-permission-btn:hover",
        "border-color" => "var(--bt-accent)",
        "color" => "var(--bt-accent)",
        "background" => "rgba(59,130,246,0.06)"),
    CSS(".bt-permission-btn.bt-perm-allow:hover",
        "border-color" => "var(--bt-success)", "color" => "#047857",
        "background" => "rgba(16,185,129,0.08)"),
    CSS(".bt-permission-btn.bt-perm-reject:hover",
        "border-color" => "var(--bt-error)", "color" => "#b91c1c",
        "background" => "rgba(239,68,68,0.08)"),
    CSS(".bt-permission-btn:disabled",
        "opacity" => "0.5", "cursor" => "default"),
    CSS(".bt-permission-btn.bt-perm-chosen",
        "opacity" => "1",
        "border-color" => "var(--bt-accent)",
        "background" => "rgba(59,130,246,0.12)",
        "color" => "var(--bt-accent-hover)"),
    # Question-form extras (AskUserQuestion): per-question label for
    # multi-question forms, the free-text "Other" box, and the action row.
    CSS(".bt-question-field-label",
        "font-size" => "12.5px",
        "color" => "var(--bt-text-muted)",
        "margin-top" => "2px"),
    CSS("input.bt-question-text",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-bg)",
        "color" => "var(--bt-text)",
        "font" => "inherit", "font-size" => "13px",
        "padding" => "7px 10px",
        "outline" => "none",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS("input.bt-question-text:focus",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    CSS(".bt-permission-actions",
        "display" => "flex", "gap" => "8px",
        "justify-content" => "flex-end",
        "border-top" => "1px solid var(--bt-border)",
        "padding-top" => "8px"),
    CSS(".bt-question-skip",
        "color" => "var(--bt-text-muted)"),

    # ── New-messages pill ────────────────────────────────────────────────────
    # Floats above the input area when followMode is off and new content
    # arrived in scrollback. Click → re-engage follow + scroll to bottom.
    # Hidden by default; .bt-new-msg-pill-visible toggles display. The slow
    # 2.5s pulse is via box-shadow so the button geometry doesn't shift.
    CSS(".bt-new-msg-pill",
        "display" => "none",
        "position" => "absolute",
        "left" => "50%",
        # Bottom offset sits above the input area; chosen large enough
        # that on mobile (where the input area can grow to ~120px with
        # an expanded textarea + attachments strip) the pill stays clear.
        "bottom" => "92px",
        "transform" => "translateX(-50%)",
        "z-index" => "20",
        "align-items" => "center", "gap" => "8px",
        "padding" => "8px 16px",
        "border" => "none", "border-radius" => "999px",
        "background" => "linear-gradient(135deg, #10b981 0%, #059669 100%)",
        "color" => "#fff",
        "font-family" => "inherit", "font-size" => "13px",
        "font-weight" => "500",
        "cursor" => "pointer",
        "box-shadow" => "0 4px 14px rgba(16, 185, 129, 0.45)",
        "animation" => "bt-new-msg-pulse 2.5s ease-in-out infinite"),
    CSS(".bt-new-msg-pill.bt-new-msg-pill-visible",
        "display" => "inline-flex"),
    CSS(".bt-new-msg-pill:hover",
        "filter" => "brightness(1.08)"),
    CSS(".bt-new-msg-pill:active",
        "transform" => "translateX(-50%) scale(0.96)"),
    CSS(".bt-new-msg-pill-arrow",
        "font-size" => "16px", "line-height" => "1"),
    CSS("@keyframes bt-new-msg-pulse",
        CSS("0%, 100%",
            "box-shadow" => "0 4px 14px rgba(16, 185, 129, 0.45)"),
        CSS("50%",
            "box-shadow" => "0 4px 28px rgba(16, 185, 129, 0.85)")),

    # ── Input area ───────────────────────────────────────────────────────────
    # Outer area spans full width (so the top border + background look right);
    # inner row is centered with the same max-width as the messages column.
    # Column flex so the thumbnail strip (.bt-attachments) sits above the
    # input row when an attachment is queued.
    CSS(".bt-input-area",
        "flex-shrink" => "0",
        "border-top" => "1px solid var(--bt-border)",
        "padding" => "12px 14px",
        "padding-bottom" => "max(12px, env(safe-area-inset-bottom))",
        "display" => "flex", "flex-direction" => "column", "align-items" => "center",
        "gap" => "8px",
        "background" => "var(--bt-surface)"),
    CSS(".bt-input-row",
        "display" => "flex", "gap" => "8px", "align-items" => "flex-end",
        "width" => "100%"),

    # ── Chat toolbar (below the composer) ───────────────────────────────────
    # Hosts the message-type filter checkboxes (populated client-side by
    # `noteType` in bonitoagents.js) and future per-chat options. Deliberately
    # roomy (min-height) so it doesn't jump when the first checkbox appears.
    # Two rows: the dynamic message-filter checkboxes (top) and static
    # display options (bottom, e.g. "Depict Images Natively in Chat").
    CSS(".bt-chat-toolbar",
        "flex-shrink" => "0",
        "min-height" => "38px",
        "box-sizing" => "border-box",
        "display" => "flex", "flex-direction" => "column",
        # Roomy row separation so the display options read as their own
        # group, distinct from the filter checkboxes above.
        "gap" => "10px",
        "padding" => "8px 14px",
        "border-top" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)",
        "font-size" => "12px",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-toolbar-filters",
        "display" => "flex", "align-items" => "center", "flex-wrap" => "wrap",
        "gap" => "14px", "min-height" => "18px"),
    CSS(".bt-toolbar-options",
        "display" => "flex", "align-items" => "center", "flex-wrap" => "wrap",
        "gap" => "14px"),
    CSS(".bt-filter-toggle",
        "display" => "inline-flex", "align-items" => "center", "gap" => "5px",
        "cursor" => "pointer",
        "white-space" => "nowrap"),
    CSS(".bt-filter-toggle input",
        "cursor" => "pointer", "margin" => "0"),
    CSS(".bt-filter-toggle:hover",
        "color" => "var(--bt-text)"),
    # "Tools:" group separator before the per-tool checkboxes. (Hiding itself
    # is inline display:none managed by bonitoagents.js `setKeyHidden` — the
    # per-tool key set is open, so no static rules.)
    CSS(".bt-filter-group-label",
        "margin-left" => "8px",
        "font-weight" => "600"),

    # ── Native media display (bt_show + "Native Images" / "Native Videos") ──
    # The bt-tool-native class strips the pill chrome so the body's <img> or
    # <video> sits bare in the chat flow like an agent reply; bonitoagents.js
    # applies it (and auto-mounts the body) when the matching toggle is on
    # and the tool's show_mime is image/* / video/*.
    CSS(".bt-tool-msg.bt-tool-native",
        "background" => "none",
        "border" => "none",
        "box-shadow" => "none",
        "overflow" => "visible"),
    CSS(".bt-tool-native .bt-tool-header", "display" => "none"),
    # The full-width toggle lives inside the (hidden) header now, but keep an
    # explicit hide that out-ranks the expanded-state reveal rule in case a
    # future layout moves it back out of the header.
    CSS(".bt-tool-native .bt-tool-fullwidth, " *
        ".bt-tool-native .bt-tool-header[data-expanded=\"true\"] .bt-tool-fullwidth",
        "display" => "none"),
    CSS(".bt-tool-native .bt-tool-body",
        "border-top" => "none",
        "padding" => "0"),
    CSS(".bt-tool-native .bt-tool-body img",
        "border-radius" => "var(--bt-radius-sm)",
        "box-shadow" => "var(--bt-shadow-sm)",
        # Subtle hover lift: barely-there zoom + deeper shadow. transform
        # doesn't reflow the layout, so the virtual-scroll heights are
        # untouched by hovering.
        "transition" => "transform 150ms ease, box-shadow 150ms ease"),
    CSS(".bt-tool-native .bt-tool-body img:hover",
        "transform" => "scale(1.015)",
        "box-shadow" => "var(--bt-shadow-md)"),
    # Videos get the same dressing but NOT the hover lift — a zoom under
    # the pointer while scrubbing/watching reads as jitter, not polish.
    CSS(".bt-tool-native .bt-tool-body video",
        "border-radius" => "var(--bt-radius-sm)",
        "box-shadow" => "var(--bt-shadow-sm)"),

    # ── Attachment thumbnail strip ──────────────────────────────────────────
    # Sits above .bt-input-row. Hidden (display:none) when there's nothing
    # queued so the empty div doesn't add stray spacing. Thumbnails scroll
    # horizontally on overflow rather than wrapping — keeps the input row
    # in the same screen position regardless of attachment count.
    CSS(".bt-attachments",
        "display" => "none",
        "width" => "100%"),
    CSS(".bt-attachments.bt-attachments-active",
        "display" => "flex",
        "gap" => "8px",
        "flex-wrap" => "wrap",
        "align-items" => "flex-start"),
    CSS(".bt-attachment-thumb",
        "position" => "relative",
        "width" => "64px", "height" => "64px",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "8px",
        "overflow" => "hidden",
        "background" => "var(--bt-bg)",
        "flex-shrink" => "0"),
    CSS(".bt-attachment-thumb img",
        "width" => "100%", "height" => "100%",
        "object-fit" => "cover",
        "display" => "block"),
    CSS(".bt-attachment-remove",
        "position" => "absolute",
        "top" => "2px", "right" => "2px",
        "width" => "20px", "height" => "20px",
        "border" => "none", "border-radius" => "50%",
        "background" => "rgba(0,0,0,0.6)", "color" => "#fff",
        "font-size" => "16px", "line-height" => "20px",
        "padding" => "0", "cursor" => "pointer",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "center"),
    CSS(".bt-attachment-remove:hover",
        "background" => "rgba(220,38,38,0.85)"),
    CSS(".bt-attach-error",
        "color" => "var(--bt-error)",
        "font-size" => "12px",
        "padding" => "4px 8px",
        "border-radius" => "6px",
        "background" => "rgba(239,68,68,0.08)",
        "border" => "1px solid rgba(239,68,68,0.3)",
        "flex-basis" => "100%",
        "box-sizing" => "border-box"),

    # Drag-over highlight on .bt-app: subtle inset ring so it's clear the
    # drop zone is "the whole chat", not just one nested element.
    CSS(".bt-app.bt-drag-over",
        "box-shadow" => "inset 0 0 0 3px var(--bt-accent)"),
    CSS(".bt-text-input",
        "flex" => "1 1 auto", "min-width" => "0",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "20px",
        "padding" => "10px 14px",
        "font-size" => "16px",                          # iOS no-zoom threshold
        "min-height" => "40px", "max-height" => "120px",
        "font-family" => "inherit",
        "color" => "var(--bt-text)",
        "background" => "var(--bt-bg)",
        "outline" => "none", "box-sizing" => "border-box",
        "resize" => "none", "overflow-y" => "auto",
        "line-height" => "1.4",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-text-input::placeholder",
        "color" => "var(--bt-text-faint)"),
    CSS(".bt-text-input:focus",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    # Thin, modern scrollbar instead of the Linux/Electron default with up/down
    # arrow buttons. Only visible when textarea grows past max-height.
    CSS(".bt-text-input",
        "scrollbar-width" => "thin",
        "scrollbar-color" => "var(--bt-border-strong) transparent"),
    CSS(".bt-text-input::-webkit-scrollbar",
        "width" => "6px"),
    CSS(".bt-text-input::-webkit-scrollbar-thumb",
        "background" => "var(--bt-border-strong)",
        "border-radius" => "3px"),
    CSS(".bt-text-input::-webkit-scrollbar-button",
        "display" => "none"),

    # Send / stop buttons — circles, big enough for thumb. `box-sizing:
    # border-box` is load-bearing: stop has a 1px border, send doesn't, so
    # without it the buttons end up 42x42 vs 40x40 and the row baselines
    # disagree by a pixel.
    CSS(".bt-send-btn, .bt-stop-btn",
        "border" => "none", "border-radius" => "50%",
        "width" => "40px", "height" => "40px",
        "box-sizing" => "border-box",
        "font-size" => "20px",                       # larger glyph fills the circle
        "line-height" => "1",
        "cursor" => "pointer", "flex-shrink" => "0",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "center", "padding" => "0",
        "transition" => "background 120ms, transform 80ms, opacity 120ms"),
    CSS(".bt-send-btn",
        "background" => "var(--bt-accent)", "color" => "#fff"),
    CSS(".bt-send-btn:hover",  "background" => "var(--bt-accent-hover)"),
    CSS(".bt-send-btn:active", "transform" => "scale(0.95)"),
    CSS(".bt-send-btn:disabled",
        "opacity" => "0.4", "cursor" => "not-allowed"),
    CSS(".bt-stop-btn",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-error)",
        "border" => "1px solid var(--bt-border-strong)"),
    CSS(".bt-stop-btn:hover",
        "background" => "rgba(239,68,68,0.08)",
        "border-color" => "var(--bt-error)"),

    # ── Spinner (used by bt_show preview while streaming from worker) ────────
    CSS(".bt-spinner",
        "width" => "14px", "height" => "14px",
        "border-radius" => "50%",
        "border" => "2px solid var(--bt-border)",
        "border-top-color" => "var(--bt-accent)",
        "will-change" => "transform",   # compositor-driven; survives main-thread jank
        "animation" => "bt-spin 0.7s linear infinite",
        "flex-shrink" => "0",
        "display" => "inline-block"),
    # Explicit `from` so it's an angle interpolation (0°→360°); `to` alone
    # interpolates matrix→identity and never turns. See dashboard.jl bt-spin.
    CSS("@keyframes bt-spin",
        CSS("from", "transform" => "rotate(0deg)"),
        CSS("to", "transform" => "rotate(360deg)")),

    # ── Responsive ───────────────────────────────────────────────────────────
    CSS("@media (max-width: 480px)",
        # Tighter padding on very small screens
        CSS(".bt-messages", "padding" => "12px"),
        CSS(".bt-input-area", "padding" => "10px 12px",
            "padding-bottom" => "max(10px, env(safe-area-inset-bottom))"),
        # Slightly tighter bubbles
        CSS(".bt-user-msg, .bt-agent-msg", "max-width" => "88%"),
        CSS(".bt-tool-msg",                "max-width" => "100%"),
        CSS(".bt-plan-msg",                "max-width" => "100%"),
        CSS(".bt-summary-msg",             "max-width" => "92%"),
        # Hide the cwd path in the header — not enough room
        CSS(".bt-header-cwd", "display" => "none"),
        # Title takes the available horizontal space and ellipsizes; the
        # sync button shrinks to its content width. On desktop the sync
        # button reserves 260px so per-file progress labels don't reflow
        # the header, but on a 360-414px phone column that 260px reserve
        # covers the project name. Drop it on mobile: long progress labels
        # still truncate via `text-overflow: ellipsis` (declared on the
        # base `.bt-header-sync` rule), so the row never overflows.
        CSS(".bt-header-title", "flex" => "1 1 auto"),
        CSS(".bt-header-sync",
            "min-width" => "0", "max-width" => "none",
            "flex" => "0 1 auto"),
        # Tool/message hide-toggles toolbar: on desktop the two `flex-wrap:
        # wrap` rows are fine; on mobile, 10–20 filter checkboxes at ~80px
        # each wrap into 4–6 stacked rows, growing the toolbar to ~120px
        # tall and eating the message column. Confine each row to a single
        # horizontally-scrollable strip — the user swipes to reach the
        # off-screen toggles, but the vertical footprint stays at one row.
        CSS(".bt-chat-toolbar",
            "padding" => "6px 10px",
            "gap" => "6px",
            "min-height" => "0"),
        CSS(".bt-toolbar-filters, .bt-toolbar-options",
            "flex-wrap" => "nowrap",
            "overflow-x" => "auto",
            "-webkit-overflow-scrolling" => "touch",
            "gap" => "10px",
            "padding-bottom" => "2px")),
)
