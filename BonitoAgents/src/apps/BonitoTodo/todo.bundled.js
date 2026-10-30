// deno-fmt-ignore-file
// deno-lint-ignore-file
// This code was bundled using `deno bundle` and it's not recommended to edit it manually

function connect({ bar , form , list  }, rows, act) {
    const send = (name, id, value)=>act.notify([
            name,
            id,
            value
        ]);
    const counts = bar.querySelector('.bt-todo-counts');
    const showDone = bar.querySelector('.bt-todo-showdone');
    let current = rows.value;
    const render = ()=>{
        const { open , done  } = current;
        counts.textContent = `${open.length} open · ${done.length} done`;
        const shown = showDone.checked ? open.concat(done) : open;
        if (shown.length === 0) {
            const empty = el('div', 'bt-todo-empty');
            empty.textContent = open.length + done.length === 0 ? 'Nothing to do yet.' : 'All done.';
            list.replaceChildren(empty);
        } else {
            list.replaceChildren(...shown.map(item));
        }
    };
    rows.on((value)=>{
        current = value;
        render();
    });
    showDone.addEventListener('change', render);
    render();
    form.addEventListener('submit', (e)=>{
        e.preventDefault();
        const input = form.querySelector('.bt-todo-input');
        const text = input.value.trim();
        if (!text) return;
        send('add', 0, text);
        input.value = '';
    });
    list.addEventListener('click', (e)=>{
        const b = e.target.closest('[data-act]');
        if (!b) return;
        send(b.dataset.act, rowId(b), b.dataset.value || null);
    });
    list.addEventListener('change', (e)=>{
        if (e.target.matches('.bt-todo-check')) send('check', rowId(e.target), e.target.checked);
    });
    list.addEventListener('dblclick', (e)=>{
        const text = e.target.closest('.bt-todo-text');
        if (!text || text.isContentEditable) return;
        const before = text.textContent;
        text.contentEditable = 'plaintext-only';
        text.focus();
        const finish = (save)=>{
            text.removeEventListener('keydown', key);
            text.removeEventListener('blur', blur);
            text.contentEditable = 'false';
            const now = text.textContent.trim();
            if (save && now && now !== before) send('edit', rowId(text), now);
            else text.textContent = before;
        };
        const key = (k)=>{
            if (k.key === 'Enter') {
                k.preventDefault();
                finish(true);
            } else if (k.key === 'Escape') {
                k.preventDefault();
                finish(false);
            }
        };
        const blur = ()=>finish(true);
        text.addEventListener('keydown', key);
        text.addEventListener('blur', blur);
    });
}
const rowId = (node)=>Number(node.closest('[data-todo-id]').dataset.todoId);
function el(tag, className, attrs = {}) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    for (const [k, v] of Object.entries(attrs))node.setAttribute(k, v);
    return node;
}
function button(label, className, act, title, value) {
    const b = el('button', className, {
        type: 'button',
        'data-act': act,
        title
    });
    if (value !== undefined) b.dataset.value = value;
    b.textContent = label;
    return b;
}
function item(t) {
    const done = !!t.done_label;
    const row = el('div', done ? 'bt-todo-item bt-todo-item-done' : 'bt-todo-item', {
        'data-todo-id': String(t.id)
    });
    const check = el('input', 'bt-todo-check', {
        type: 'checkbox',
        title: done ? 'Open it again' : 'Check it off'
    });
    check.checked = done;
    const id = el('span', 'bt-todo-id');
    id.textContent = `#${t.id}`;
    const text = el('span', 'bt-todo-text', {
        title: 'Double-click to edit'
    });
    text.textContent = t.text;
    const line = el('div', 'bt-todo-line');
    line.append(id, text);
    const body = el('div', 'bt-todo-body');
    body.append(line);
    const meta = t.chats.map((c)=>button(c.title, 'bt-todo-chat', 'open', 'Open this chat', c.id));
    if (done) {
        const by = el('span', 'bt-todo-done-by');
        by.textContent = t.done_label;
        meta.push(by);
    }
    if (meta.length) {
        const m = el('div', 'bt-todo-meta');
        m.append(...meta);
        body.append(m);
    }
    const actions = el('div', 'bt-todo-actions');
    if (!done) actions.append(button('Start chat', 'bw-btn bw-btn-secondary bw-btn-sm bt-todo-start', 'start', "Ask this chat's agent to start a chat for it in the right project"));
    actions.append(button('×', 'bw-btn bw-btn-ghost bw-btn-sm bt-todo-remove', 'remove', 'Remove'));
    row.append(check, body, actions);
    return row;
}
export { connect as connect };

