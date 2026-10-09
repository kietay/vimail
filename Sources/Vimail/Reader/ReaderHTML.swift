import Foundation

/// The reader's HTML shell. Loaded once; threads are rendered by calling `vimail.render(json)`.
enum ReaderHTML {
    static func shell(fontFaces: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src data:; img-src data: cid: vimail-cid: https: http:; frame-src about: data:; child-src about: data:">
        <style>\(fontFaces)</style>
        <style>\(css)</style>
        </head><body><div id="root"><div class="empty">Select a message</div></div>
        <script>\(script)</script>
        </body></html>
        """
    }

    static let css = """
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--reader); color: var(--foreground); font-family: 'DM Sans', -apple-system, sans-serif;
      -webkit-font-smoothing: antialiased; }
    body { padding: 20px 24px 40px 24px; }
    @media (min-width: 1000px) { body { padding-left: 36px; padding-right: 36px; } }
    ::selection { background: var(--selection); color: var(--foreground); }
    button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; transition: background-color .15s, color .15s, opacity .15s; }
    svg.icon { fill: none; stroke: currentColor; stroke-linecap: round; stroke-linejoin: round; flex-shrink: 0; }
    .mono { font-family: 'IBM Plex Mono', ui-monospace, monospace; }
    .muted { color: var(--muted-foreground); }

    header.thread { margin-bottom: 20px; padding-bottom: 16px; border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent); }
    .subject-row { display: flex; align-items: flex-start; gap: 12px; }
    h1.subject { flex: 1; min-width: 0; margin: 0; font-size: 22px; font-weight: 500; line-height: 1.4; letter-spacing: 0; }
    .icon-button { width: 28px; height: 28px; border-radius: 6px; display: flex; align-items: center; justify-content: center; color: var(--muted-foreground); flex-shrink: 0; }
    .icon-button:hover { background: var(--muted); color: var(--foreground); }
    .menu-wrap { position: relative; }
    .menu { position: absolute; right: 0; top: 36px; z-index: 20; width: 256px; border-radius: 12px; border: 1px solid var(--border); background: var(--reader);
      padding: 6px; box-shadow: 0 18px 50px -12px rgba(0,0,0,.45); display: none; }
    .menu.open { display: block; }
    .menu button { display: flex; width: 100%; align-items: center; gap: 10px; border-radius: 6px; padding: 10px; text-align: left; font-size: 11px; color: var(--body); }
    .menu button:hover { background: var(--muted); }
    .menu button .label { flex: 1; }
    .menu hr { border: 0; border-top: 1px solid var(--border); margin: 4px 6px; }
    kbd { display: inline-flex; min-width: 20px; align-items: center; justify-content: center; border-radius: 4px; border: 1px solid var(--border);
      background: var(--background); padding: 1px 6px; font: 10px/16px 'IBM Plex Mono', monospace; color: var(--muted-foreground); }
    .hint { opacity: 0; transition: opacity .15s; }
    button:hover .hint, .show-hints .hint { opacity: 1; }

    .meta-row { margin-top: 12px; display: flex; flex-wrap: wrap; align-items: center; column-gap: 12px; row-gap: 8px; }
    .sender { display: flex; align-items: center; gap: 8px; font-size: 12px; cursor: pointer; min-width: 0; }
    .avatar { width: 24px; height: 24px; border-radius: 50%; background: var(--muted); color: var(--muted-foreground); font: 9px 'IBM Plex Mono', monospace;
      display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
    .sender .name { font-weight: 500; color: var(--foreground); white-space: nowrap; }
    .sender .to { font-size: 10px; color: var(--muted-foreground); white-space: nowrap; }
    .details { display: none; margin-top: 8px; padding-left: 32px; font-size: 10px; line-height: 20px; color: var(--muted-foreground); }
    .details.open { display: block; }
    .details span { color: var(--body); }
    .chip { border-radius: 4px; padding: 2px 6px; font: 9px 'IBM Plex Mono', monospace; white-space: nowrap; }
    .time { margin-left: auto; font-size: 10px; color: var(--muted-foreground); white-space: nowrap; }
    .position { display: flex; align-items: center; gap: 4px; color: var(--muted-foreground); }
    .position .count { margin-right: 4px; font: 9px 'IBM Plex Mono', monospace; }
    .nav-button { width: 24px; height: 24px; border-radius: 4px; display: flex; align-items: center; justify-content: center; }
    .nav-button:hover { background: var(--muted); }
    .nav-button:disabled { opacity: .3; cursor: default; background: none; }

    .message { position: relative; }
    .message + .message { border-top: 1px solid color-mix(in srgb, var(--border) 50%, transparent); }
    .message.multi { padding: 14px 0 14px 14px; }
    .message.multi::before { content: ''; position: absolute; left: 0; top: 18px; bottom: 18px; width: 2px; border-radius: 2px; background: transparent; }
    .message.multi.focused::before { background: var(--green); }
    .message-head { display: flex; align-items: center; gap: 10px; font-size: 12px; cursor: pointer; }
    .message-head .name { font-weight: 500; color: var(--foreground); white-space: nowrap; }
    .message-head .snippet { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--muted-foreground); font-size: 11px; }
    .message-head .when { margin-left: auto; font: 9px 'IBM Plex Mono', monospace; color: var(--muted-foreground); white-space: nowrap; }
    .message.collapsed .message-content { display: none; }
    .message:not(.collapsed) .message-head { display: none; }
    .message.multi .meta-row { cursor: pointer; }
    .message.multi .message-content { margin-top: 14px; }
    .unread-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--primary); flex-shrink: 0; }
    .sending { font: 9px 'IBM Plex Mono', monospace; color: var(--orange); }

    article.text { max-width: 680px; font-size: 15px; line-height: 1.85; color: var(--body); overflow-wrap: anywhere; }
    article.text p { margin: 0 0 20px 0; }
    article.text strong, article.text b { color: var(--foreground); font-weight: 500; }
    article.text a { color: var(--green); }
    article.text h1, article.text h2, article.text h3 { color: var(--foreground); font-weight: 500; line-height: 1.4; }
    article.text blockquote { margin: 0 0 20px 0; padding-left: 14px; border-left: 2px solid var(--border); color: var(--muted-foreground); }
    article.text pre, article.text code { font-family: 'IBM Plex Mono', monospace; font-size: 13px; }
    article.text pre { white-space: pre-wrap; background: var(--muted); border-radius: 6px; padding: 10px 12px; }
    article.text table { border-collapse: collapse; }
    article.text td, article.text th { padding: 4px 8px; vertical-align: top; }
    article.text img { max-width: 100%; height: auto; }
    .signature { margin-top: 28px; border-left: 2px solid var(--border); padding-left: 14px; font-size: 11px; line-height: 20px; color: var(--muted-foreground); white-space: normal; }
    .signature a { color: var(--green); text-decoration: none; }
    details.quote { margin: 0 0 16px 0; }
    details.quote > summary { list-style: none; display: inline-block; cursor: pointer; padding: 0 8px; border-radius: 4px; background: var(--muted);
      color: var(--muted-foreground); font: 11px/18px 'IBM Plex Mono', monospace; }
    details.quote > summary::-webkit-details-marker { display: none; }
    .quote-body { margin-top: 12px; border-left: 2px solid var(--border); padding-left: 12px; color: var(--muted-foreground); font-size: 13px; line-height: 1.7; white-space: pre-wrap; }

    .card { background: #ffffff; border-radius: 12px; padding: 4px; max-width: 760px; color-scheme: light; }
    iframe.html { display: block; width: 100%; border: 0; height: 120px; background: transparent; }
    .images-banner { max-width: 680px; display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 0 0 16px 0; padding: 8px 12px;
      border: 1px dashed var(--border); border-radius: 6px; font-size: 11px; color: var(--muted-foreground); }
    .images-banner button { color: var(--green); font-size: 11px; }

    .attachments { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 20px; }
    .attachment { width: 260px; display: flex; align-items: center; gap: 12px; border-radius: 6px; border: 1px solid color-mix(in srgb, var(--border) 60%, transparent);
      background: color-mix(in srgb, var(--muted) 50%, transparent); padding: 10px; text-align: left; }
    .attachment:hover { background: var(--muted); }
    .attachment .file { width: 32px; height: 36px; border-radius: 4px; border: 1px solid var(--border); background: var(--orange-soft); color: var(--orange);
      display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
    .attachment .text { min-width: 0; flex: 1; }
    .attachment .name { font-size: 11px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; color: var(--foreground); }
    .attachment .meta { margin-top: 4px; font: 9px 'IBM Plex Mono', monospace; color: var(--muted-foreground); text-transform: uppercase; }

    .actions { margin-top: 24px; display: flex; gap: 12px; border-top: 1px solid color-mix(in srgb, var(--border) 50%, transparent); padding-top: 16px; }
    .action { display: flex; align-items: center; gap: 10px; border-radius: 6px; padding: 10px 16px; font-size: 11px; }
    .action.primary { background: var(--green-soft); color: var(--green); font-weight: 500; }
    .action.secondary { border: 1px solid var(--border); color: var(--muted-foreground); }
    .action.secondary:hover { color: var(--foreground); }
    .empty { display: flex; height: calc(100vh - 80px); align-items: center; justify-content: center; color: var(--muted-foreground); font-size: 14px; }
    .annotations { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
    """

    static let script = #"""
    (function () {
      const post = (message) => window.webkit && window.webkit.messageHandlers.vimail.postMessage(message);
      const root = document.getElementById('root');
      let state = null;
      let focused = 0;

      const icons = {
        more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
        chevron: '<path d="m9 5 7 7-7 7"/>',
        chevronLeft: '<path d="m15 5-7 7 7 7"/>',
        down: '<path d="m5 9 7 7 7-7"/>',
        file: '<path d="M6 3h9l4 4v14H6Z"/><path d="M14 3v5h5"/>',
        reply: '<path d="m9 5-6 6 6 6 M3 11h10c5 0 8 3 8 8"/>',
        arrow: '<path d="M5 12h14 m-5-5 5 5-5 5"/>',
        archive: '<path d="M4 8h16v13H4Z M3 3h18v5H3Z M9 12h6"/>',
        trash: '<path d="M3 6h18 M9 6V3h6v3 M5 6l1 15h12l1-15 M10 10v7 M14 10v7"/>',
        star: '<path d="m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-3-5.6 3 1.1-6.2L3 9.6l6.2-.9Z"/>',
        clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
        check: '<path d="m5 12 4 4 10-10"/>',
        tag: '<path d="M3 12V4h8l10 10-8 8L3 12Z"/><circle cx="7.5" cy="8" r="1.2"/>',
        folder: '<path d="M3 6h6l2 2h10v11H3Z"/>',
        spam: '<path d="M12 3 21 19H3Z M12 10v4 M12 17v.5"/>',
        inbox: '<path d="M4 4h16l2 10v6H2v-6L4 4Z"/><path d="M2 14h6l2 3h4l2-3h6"/>',
        unsubscribe: '<path d="M21 12V5H3v14h9"/><path d="m3 6 9 7 9-7"/><path d="M15 18h6"/>',
      };
      const icon = (name, size) => `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" stroke-width="1.5">${icons[name] || icons.file}</svg>`;
      const esc = (text) => String(text ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
      const linkify = (html) => html.replace(/(^|[\s(])(https?:\/\/[^\s<]+[^\s<.,;:!?)\]])/g, '$1<a href="$2">$2</a>');

      function textBody(text) {
        const lines = text.replace(/\r\n/g, '\n').split('\n');
        let signatureAt = -1, quoteAt = -1;
        for (let i = 0; i < lines.length; i++) {
          const line = lines[i];
          if (quoteAt < 0 && /^On .+wrote:\s*$/.test(line.trim()) ) { quoteAt = i; break; }
          if (quoteAt < 0 && line.startsWith('>') && lines.slice(i).every((l) => l.startsWith('>') || l.trim() === '')) { quoteAt = i; break; }
          if (signatureAt < 0 && (line === '-- ' || line === '--')) signatureAt = i;
        }
        const end = quoteAt >= 0 ? quoteAt : lines.length;
        const mainEnd = signatureAt >= 0 && signatureAt < end ? signatureAt : end;
        const paragraphs = lines.slice(0, mainEnd).join('\n').trim().split(/\n{2,}/).filter(Boolean)
          .map((p) => `<p>${linkify(esc(p)).replace(/\n/g, '<br>')}</p>`).join('');
        let html = paragraphs;
        if (signatureAt >= 0 && signatureAt < end) {
          const sig = lines.slice(signatureAt + 1, end).join('\n').trim();
          if (sig) html += `<div class="signature">${linkify(esc(sig)).replace(/\n/g, '<br>')}</div>`;
        }
        if (quoteAt >= 0) {
          const quote = lines.slice(quoteAt).join('\n').trim();
          html += `<details class="quote"><summary>···</summary><div class="quote-body">${linkify(esc(quote))}</div></details>`;
        }
        return `<article class="text">${html}</article>`;
      }

      // Keeps simple formatting from human-written HTML and drops everything else.
      const allowed = new Set(['P','BR','DIV','SPAN','STRONG','B','EM','I','U','S','A','UL','OL','LI','BLOCKQUOTE','PRE','CODE','H1','H2','H3','H4','H5','H6','HR','TABLE','THEAD','TBODY','TR','TD','TH','IMG','FONT','SMALL','SUB','SUP','DEL']);
      const dropWithContent = new Set(['SCRIPT','STYLE','HEAD','TITLE','IFRAME','OBJECT','EMBED','FORM','INPUT','BUTTON','SELECT','TEXTAREA','SVG','MATH','LINK','META','NOSCRIPT','VIDEO','AUDIO']);
      function sanitize(html, allowRemote, counter) {
        const doc = new DOMParser().parseFromString(html, 'text/html');
        const walk = (node) => {
          for (const child of Array.from(node.childNodes)) {
            if (child.nodeType === Node.COMMENT_NODE) { child.remove(); continue; }
            if (child.nodeType !== Node.ELEMENT_NODE) continue;
            if (dropWithContent.has(child.tagName)) { child.remove(); continue; }
            if (!allowed.has(child.tagName)) { walk(child); child.replaceWith(...child.childNodes); continue; }
            const keepClass = child.classList.contains('signature') ? 'signature' : null;
            for (const attr of Array.from(child.attributes)) {
              const name = attr.name.toLowerCase();
              const keep = (name === 'href' && /^(https?:|mailto:)/i.test(attr.value)) || (name === 'src' && child.tagName === 'IMG') || name === 'colspan' || name === 'rowspan';
              if (!keep) child.removeAttribute(attr.name);
            }
            if (keepClass) child.className = keepClass;
            if (child.tagName === 'IMG') {
              const src = child.getAttribute('src') || '';
              if (/^(data|vimail-cid):/i.test(src)) {} else if (/^https?:/i.test(src) && allowRemote) {} else {
                if (/^https?:/i.test(src)) counter.blocked++;
                child.remove(); continue;
              }
            }
            walk(child);
          }
        };
        walk(doc.body);
        return doc.body.innerHTML;
      }

      // `height`: the frame's size in the previous render, so the page does not jump while it reloads.
      function richFrame(message, index, height) {
        const csp = `default-src 'none'; style-src 'unsafe-inline' data:; font-src data:; img-src data: cid: vimail-cid:${state.allowRemote ? ' https: http:' : ''};`;
        const doc = `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="${csp}"><base target="_blank">` +
          `<style>html,body{margin:0;padding:0;background:#ffffff;color:#1f2328;font-family:-apple-system,'Helvetica Neue',Arial,sans-serif;}img{max-width:100%;height:auto;}</style></head><body>${message.html}</body></html>`;
        const size = height ? ` style="height:${esc(height)}"` : '';
        return `<div class="card"><iframe class="html" data-index="${index}"${size} sandbox="allow-same-origin allow-popups allow-popups-to-escape-sandbox" srcdoc="${esc(doc)}"></iframe></div>`;
      }

      function attachmentsHTML(message) {
        if (!message.attachments.length) return '';
        return `<div class="attachments">${message.attachments.map((a) => `
          <button class="attachment" data-message="${esc(message.id)}" data-attachment="${esc(a.id)}" title="Open ${esc(a.name)} (go)">
            <span class="file">${icon('file', 17)}</span>
            <span class="text"><div class="name">${esc(a.name)}</div><div class="meta">${esc(a.kind)} · ${esc(a.size)}</div></span>
            ${icon('down', 14)}
          </button>`).join('')}</div>`;
      }

      function bodyHTML(message, index, frameHeight) {
        if (message.kind === 'rich') return richFrame(message, index, frameHeight);
        if (message.kind === 'html') {
          const counter = { blocked: 0 };
          const clean = sanitize(message.html, state.allowRemote, counter);
          state.blockedImages = (state.blockedImages || 0) + counter.blocked;
          return `<article class="text">${clean}</article>`;
        }
        return textBody(message.text || '');
      }

      function senderBlock(message, withPosition) {
        const chips = withPosition ? state.labels.map((l) => `<span class="chip" style="background:${l.soft};color:${l.fg}">${esc(l.name)}</span>`).join('') : '';
        const position = withPosition ? `
          <div class="position">
            <span class="count">${esc(state.position)}</span>
            <button class="nav-button" data-action="previous" title="Previous (k)" ${state.hasPrevious ? '' : 'disabled'}>${icon('chevronLeft', 12)}</button>
            <button class="nav-button" data-action="next" title="Next (j)" ${state.hasNext ? '' : 'disabled'}>${icon('chevron', 12)}</button>
          </div>` : '';
        // In a conversation, a dot marks the messages that are new.
        const newDot = !withPosition && message.isNew ? '<span class="unread-dot" title="New"></span>' : '';
        return `
          <div class="meta-row">
            <div class="sender" data-toggle-details>
              <span class="avatar">${esc(message.initials)}</span>
              <span class="name">${esc(message.fromName)}</span>
              ${newDot}
              <span class="to">${esc(message.toShort)}</span>
              ${icon('down', 10)}
            </div>
            ${chips}
            ${message.sending ? '<span class="sending">SENDING…</span>' : ''}
            <span class="time">${esc(message.time)}</span>
            ${position}
          </div>
          <div class="details">
            <div>From: <span>${esc(message.fromFull)}</span></div>
            <div>To: <span>${esc(message.toFull)}</span></div>
            ${message.ccFull ? `<div>Cc: <span>${esc(message.ccFull)}</span></div>` : ''}
            <div>${esc(message.dateLong)}</div>
          </div>`;
      }

      function menuHTML() {
        return `<div class="menu">${state.menu.map((item) => item.separator ? '<hr>' : `
          <button data-action="${esc(item.action)}">${icon(item.icon, 14)}<span class="label">${esc(item.title)}</span>${item.key ? `<kbd>${esc(item.key)}</kbd>` : ''}</button>`).join('')}</div>`;
      }

      // What you expanded, focused and scrolled to. A render of the conversation already on screen (marked
      // read, synced, starred, a reply arrived) keeps it. Messages not shown before start as the payload says.
      function viewState() {
        const expanded = new Map(), frameHeights = new Map();
        document.querySelectorAll('.message[data-id]').forEach((node) => {
          expanded.set(node.dataset.id, !node.classList.contains('collapsed'));
          const frame = node.querySelector('iframe.html');
          if (frame && frame.style.height) frameHeights.set(node.dataset.id, frame.style.height);
        });
        const focusedMessage = state.messages[focused];
        return { expanded, frameHeights, focusedID: focusedMessage && focusedMessage.id, scrollY: window.scrollY };
      }

      function render(payload) {
        const kept = state && state.threadID && state.threadID === payload.threadID ? viewState() : null;
        state = payload;
        state.blockedImages = 0;
        document.documentElement.style.colorScheme = payload.dark ? 'dark' : 'light';
        if (!payload.messages || !payload.messages.length) {
          root.innerHTML = `<div class="empty">${esc(payload.emptyText || 'Select a message')}</div>`;
          return;
        }
        const multi = payload.messages.length > 1;
        const first = payload.messages[0];
        const newCount = payload.messages.filter((m) => m.isNew).length;
        let html = `
          <header class="thread">
            <div class="subject-row">
              <h1 class="subject">${esc(payload.subject || '(no subject)')}</h1>
              <div class="menu-wrap">
                <button class="icon-button" data-menu title="Message actions · also in ⌘K">${icon('more', 18)}</button>
                ${menuHTML()}
              </div>
            </div>
            ${multi ? `<div class="meta-row">
                ${state.labels.map((l) => `<span class="chip" style="background:${l.soft};color:${l.fg}">${esc(l.name)}</span>`).join('')}
                <span class="time">${payload.messages.length} messages${newCount ? ` · ${newCount} new` : ''}</span>
                <div class="position"><span class="count">${esc(state.position)}</span>
                  <button class="nav-button" data-action="previous" ${state.hasPrevious ? '' : 'disabled'}>${icon('chevronLeft', 12)}</button>
                  <button class="nav-button" data-action="next" ${state.hasNext ? '' : 'disabled'}>${icon('chevron', 12)}</button></div>
              </div>` : senderBlock(first, true)}
          </header>`;
        payload.messages.forEach((message, index) => {
          const expanded = kept && kept.expanded.has(message.id) ? kept.expanded.get(message.id) : message.expanded;
          const collapsed = multi && !expanded;
          html += `<section class="message ${multi ? 'multi' : ''} ${collapsed ? 'collapsed' : ''}" data-index="${index}" data-id="${esc(message.id)}">`;
          if (multi) {
            html += `<div class="message-head" data-toggle-message="${index}">
                <span class="avatar">${esc(message.initials)}</span>
                <span class="name">${esc(message.fromName)}</span>
                ${message.isNew ? '<span class="unread-dot"></span>' : ''}
                <span class="snippet">${esc(message.snippet)}</span>
                <span class="when">${esc(message.time)}</span>
              </div>
              <div class="message-content">${senderBlock(message, false).replace('class="meta-row"', 'class="meta-row" style="margin:0 0 14px 0"')}`;
          } else {
            html += '<div class="message-content">';
          }
          html += bodyHTML(message, index, kept && kept.frameHeights.get(message.id)) + attachmentsHTML(message) + '</div></section>';
        });
        if (state.blockedImages > 0 && !payload.allowRemote) {
          html = html.replace('</header>', `</header><div class="images-banner"><span>Remote images are hidden to protect your privacy.</span><button data-action="loadImages">Show images</button></div>`);
        }
        // Reply/Forward live in a native bar pinned to the bottom of the pane, so they never move.
        root.innerHTML = html;
        if (payload.showHints) document.body.classList.add('show-hints'); else document.body.classList.remove('show-hints');
        const keptFocus = kept ? payload.messages.findIndex((m) => m.id === kept.focusedID) : -1;
        focused = keptFocus >= 0 ? keptFocus : Math.max(0, payload.messages.findIndex((m) => m.focus));
        if (multi) markFocused(false);
        window.scrollTo(0, kept ? kept.scrollY : 0);
        if (multi && focused > 0 && !kept) {
          const node = document.querySelector(`.message[data-index="${focused}"]`);
          if (node) window.scrollTo(0, Math.max(0, node.offsetTop - 80));
        }
        wireFrames();
      }

      function fit(frame) {
        try {
          const doc = frame.contentDocument;
          if (!doc || !doc.documentElement || !frame.offsetParent) return;
          frame.style.height = Math.max(40, doc.documentElement.scrollHeight) + 'px';
        } catch (e) {}
      }

      // Sizes each sandboxed HTML frame to its content, now and whenever it changes.
      function wireFrames() {
        document.querySelectorAll('iframe.html').forEach((frame) => {
          if (frame.dataset.wired) { fit(frame); return; }
          frame.dataset.wired = '1';
          frame.addEventListener('load', () => {
            fit(frame);
            try { new ResizeObserver(() => fit(frame)).observe(frame.contentDocument.documentElement); } catch (e) {}
            setTimeout(() => fit(frame), 250);
          });
        });
      }

      function markFocused(scroll) {
        document.querySelectorAll('.message.multi').forEach((node) => node.classList.toggle('focused', Number(node.dataset.index) === focused));
        if (scroll) {
          const node = document.querySelector(`.message[data-index="${focused}"]`);
          if (node) node.scrollIntoView({ block: 'nearest' });
        }
      }

      document.addEventListener('click', (event) => {
        const menuButton = event.target.closest('[data-menu]');
        const menu = document.querySelector('.menu');
        if (menuButton) { menu && menu.classList.toggle('open'); return; }
        if (menu && !event.target.closest('.menu')) menu.classList.remove('open');
        const action = event.target.closest('[data-action]');
        if (action) { menu && menu.classList.remove('open'); post({ type: 'action', name: action.dataset.action }); return; }
        const attachment = event.target.closest('[data-attachment]');
        if (attachment) { post({ type: 'attachment', messageID: attachment.dataset.message, attachmentID: attachment.dataset.attachment }); return; }
        const toggle = event.target.closest('[data-toggle-message]');
        if (toggle) { toggleMessage(Number(toggle.dataset.toggleMessage)); return; }
        const details = event.target.closest('[data-toggle-details]');
        if (details) { const panel = details.parentElement.nextElementSibling; if (panel && panel.classList.contains('details')) panel.classList.toggle('open'); return; }
        // Clicking an expanded message's header row (outside the sender) collapses it.
        const metaRow = event.target.closest('.message.multi .meta-row');
        if (metaRow) { toggleMessage(Number(metaRow.closest('.message').dataset.index)); }
      });

      function toggleMessage(index) {
        const node = document.querySelector(`.message[data-index="${index}"]`);
        if (!node) return;
        node.classList.toggle('collapsed');
        focused = index;
        markFocused(false);
        wireFrames();
      }

      window.vimail = {
        render,
        setTheme(vars, dark) {
          for (const [key, value] of Object.entries(vars)) document.documentElement.style.setProperty(key, value);
          document.documentElement.style.colorScheme = dark ? 'dark' : 'light';
        },
        scrollLines(count) { window.scrollBy(0, count * 48); },
        scrollPage(fraction) { window.scrollBy(0, fraction * (window.innerHeight - 60)); },
        scrollTo(where) { window.scrollTo(0, where === 'top' ? 0 : document.body.scrollHeight); },
        focusMessage(delta) {
          const nodes = document.querySelectorAll('.message.multi');
          if (!nodes.length) { this.scrollPage(delta * 0.8); return; }
          focused = Math.max(0, Math.min(nodes.length - 1, focused + delta));
          const node = nodes[focused];
          node.classList.remove('collapsed');
          markFocused(true);
          wireFrames();
        },
        toggleFocused() { toggleMessage(focused); },
        expandAll() {
          const nodes = document.querySelectorAll('.message.multi');
          const anyCollapsed = Array.from(nodes).some((n) => n.classList.contains('collapsed'));
          nodes.forEach((n) => n.classList.toggle('collapsed', !anyCollapsed));
          wireFrames();
        },
        closeMenu() { const menu = document.querySelector('.menu'); if (menu) menu.classList.remove('open'); },
      };
      post({ type: 'ready' });
    })();
    """#
}
