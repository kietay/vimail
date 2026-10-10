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
    .next-with { margin-top: 12px; display: inline-flex; align-items: center; gap: 8px; padding: 0; border: 0; background: none;
      font: 12px/1.4 'DM Sans', -apple-system, sans-serif; color: var(--muted-foreground); cursor: pointer; text-align: left; }
    .next-with svg { color: var(--blue); flex: none; }
    .next-with:hover span { color: var(--foreground); text-decoration: underline; text-underline-offset: 3px; }
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

    /* The event page: an invitation in mail, or an event in the calendar. Two columns when the reader is wide. */
    .event-page { display: grid; grid-template-columns: minmax(0, 1fr); gap: 20px; margin: 0 0 20px 0; padding-bottom: 20px;
      border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent); }
    @media (min-width: 760px) { .event-page.with-day { grid-template-columns: minmax(0, 1fr) 280px; } }
    .ev-main { display: grid; gap: 12px; align-content: start; min-width: 0; }
    .ev-kicker { font: 10px 'IBM Plex Mono', monospace; letter-spacing: .08em; text-transform: uppercase; color: var(--muted-foreground); }
    .ev-title { margin: 0; font-size: 22px; font-weight: 600; line-height: 1.3; color: var(--foreground); }
    .ev-when { font: 500 13px 'IBM Plex Mono', monospace; color: var(--blue); }
    .ev-when .muted, .ev-zone { font-weight: 400; color: var(--muted-foreground); }
    .ev-zone, .ev-repeats { font: 11px 'IBM Plex Mono', monospace; margin-top: -6px; }
    .ev-repeats { color: var(--body); }
    .ev-chips { display: flex; flex-wrap: wrap; gap: 6px; }
    .ev-chip { font: 10px/16px 'IBM Plex Mono', monospace; letter-spacing: .02em; padding: 1px 8px; border-radius: 999px; }
    .ev-chip.needs { color: var(--yellow); background: var(--yellow-soft); }
    .ev-chip.clash { color: var(--red); background: var(--red-soft); }
    .ev-chip.ok { color: var(--green); background: var(--green-soft); }
    .ev-chip.muted { color: var(--muted-foreground); background: var(--muted); }
    .ev-changes { font-size: 12px; line-height: 1.7; color: var(--body); border-left: 2px solid var(--yellow); padding-left: 10px; }
    .ev-facts { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 5px 16px; margin: 0; font-size: 12px; line-height: 1.6; }
    .ev-facts dt { font: 10px/19px 'IBM Plex Mono', monospace; letter-spacing: .06em; text-transform: uppercase; color: var(--muted-foreground); }
    .ev-facts dd { margin: 0; color: var(--body); overflow-wrap: anywhere; }
    .ev-facts a { color: var(--green); text-decoration: none; }
    .ev-guest { white-space: nowrap; }
    .ev-guest .ans { font: 10px 'IBM Plex Mono', monospace; padding: 0 5px; border-radius: 3px; color: var(--muted-foreground); background: var(--muted); }
    .ev-guest .ans.yes { color: var(--green); background: var(--green-soft); }
    .ev-guest .ans.waiting { color: var(--yellow); background: var(--yellow-soft); }
    .ev-guest .ans.no { color: var(--red); background: var(--red-soft); }
    .ev-sum { font: 10px 'IBM Plex Mono', monospace; color: var(--muted-foreground); margin-top: 2px; }
    .ev-agenda { max-width: 620px; font-size: 13px; line-height: 1.7; color: var(--body); white-space: pre-wrap; overflow-wrap: anywhere; }
    .ev-agenda a { color: var(--green); }
    .ev-answers { display: flex; flex-wrap: wrap; gap: 8px; padding-top: 2px; }
    .ev-answer { display: inline-flex; align-items: center; gap: 8px; border-radius: 6px; padding: 6px 10px 6px 12px; font-size: 11px;
      border: 1px solid var(--border); color: var(--muted-foreground); }
    .ev-answer:hover { color: var(--foreground); }
    .ev-answer.primary, .ev-answer.selected { border-color: transparent; background: var(--green-soft); color: var(--green); font-weight: 500; }
    .ev-answer kbd { min-width: 18px; }
    .ev-foot, .ev-message { font-size: 11px; color: var(--muted-foreground); }
    .ev-day { display: grid; gap: 10px; align-content: start; border-left: 1px solid color-mix(in srgb, var(--border) 70%, transparent); padding-left: 18px; }
    @media (max-width: 759px) {
      .ev-day { order: -1; border-left: 0; padding-left: 0; padding-bottom: 14px; border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
        max-height: 250px; overflow-y: auto; }
    }
    .ev-dayhead { display: flex; justify-content: space-between; align-items: baseline; font: 600 12px 'IBM Plex Mono', monospace; color: var(--foreground); }
    .ev-dayhead .muted { font-weight: 400; }
    .ev-nav { display: flex; gap: 4px; }
    .ev-allday { display: flex; flex-wrap: wrap; gap: 4px; }
    .ev-allday span { font: 10px 'IBM Plex Mono', monospace; padding: 1px 6px; border-radius: 3px; background: var(--muted); color: var(--body); }
    .ev-grid { position: relative; margin: 8px 0 8px 30px; }
    .ev-hr { position: absolute; left: 0; right: 0; border-top: 1px solid color-mix(in srgb, var(--border) 70%, transparent); }
    .ev-hl { position: absolute; left: -30px; width: 22px; text-align: right; transform: translateY(-50%); font: 10px 'IBM Plex Mono', monospace; color: var(--muted-foreground); }
    .ev-blk { position: absolute; box-sizing: border-box; border-radius: 4px; padding: 2px 6px; font: 10px/1.3 'IBM Plex Mono', monospace;
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .ev-blk.thin { font-size: 9px; line-height: 10px; padding: 0 6px; }
    .ev-blk.mine { background: var(--muted); color: var(--body); box-shadow: inset 2px 0 0 var(--green); }
    .ev-blk.maybe { background: repeating-linear-gradient(135deg, var(--muted) 0 6px, transparent 6px 10px); color: var(--body); box-shadow: inset 2px 0 0 var(--yellow); }
    .ev-blk.declined { background: var(--muted); color: var(--muted-foreground); opacity: .55; text-decoration: line-through; }
    .ev-blk.pending { background: transparent; color: var(--body); border: 1px dashed var(--muted-foreground); }
    .ev-blk.invite { background: var(--blue-soft); color: var(--blue); border: 1.5px dashed var(--blue); }
    .ev-blk.this { background: var(--blue-soft); color: var(--blue); box-shadow: inset 2px 0 0 var(--blue); }
    .ev-blk.clash { background: var(--red-soft); color: var(--red); box-shadow: inset 2px 0 0 var(--red); }
    .ev-now { position: absolute; left: -4px; right: 0; border-top: 1.5px solid var(--orange); }
    .ev-note { font-size: 11px; color: var(--muted-foreground); }
    .ev-note.clash::first-word { color: var(--red); }
    .ev-note.clash { color: var(--red); }
    .message.invitation-original .message-head .name { font-weight: 400; color: var(--muted-foreground); }
    .annotations { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
    .annotations .provenance { flex-basis: 100%; font: 10px 'IBM Plex Mono', monospace; color: var(--muted-foreground); overflow-wrap: anywhere; }
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
        calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18 M8 3v4 M16 3v4"/>',
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

      // A chip's tooltip says how rules added the label.
      function chipHTML(l) {
        const title = l.source ? ` title="${esc(l.source)}"` : '';
        return `<span class="chip" style="background:${l.soft};color:${l.fg}"${title}>${esc(l.name)}</span>`;
      }

      function provenanceHTML() {
        if (!state.provenance || !state.provenance.length) return '';
        return `<div class="annotations">${state.provenance.map((line) => `<span class="provenance">${esc(line)}</span>`).join('')}</div>`;
      }

      function senderBlock(message, withPosition) {
        const chips = withPosition ? state.labels.map(chipHTML).join('') : '';
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

      function eventPageHTML(ev) {
        const chips = (ev.chips || []).map((c) => `<span class="ev-chip ${esc(c.kind)}">${esc(c.text)}</span>`).join('');
        // Only web links become links: the event's author chooses this text.
        const facts = (ev.facts || []).map((f) => `<dt>${esc(f.label)}</dt><dd>${f.link && webLink(f.link) ? `<a href="${esc(f.link)}">${esc(f.value)}</a>` : esc(f.value)}${f.key ? ` <kbd>${esc(f.key)}</kbd>` : ''}</dd>`).join('');
        const guests = (ev.guests || []).length ? `<dt>Guests</dt><dd>${ev.guests.map((g) => `<span class="ev-guest">${esc(g.name)} <span class="ans ${esc(g.kind)}">${esc(g.answer)}</span></span>`).join(' · ')}${ev.guestSummary ? `<div class="ev-sum">${esc(ev.guestSummary)}</div>` : ''}</dd>` : '';
        const anySelected = (ev.answers || []).some((a) => a.selected);
        const answers = (ev.answers || []).length ? `<div class="ev-answers">${ev.answers.map((a, i) => `<button class="ev-answer ${a.selected ? 'selected' : ''} ${i === 0 && !anySelected ? 'primary' : ''}" data-action="${esc(a.action)}">${esc(a.title)} <kbd>${esc(a.key)}</kbd></button>`).join('')}</div>` : '';
        const main = `<div class="ev-main">
            <div class="ev-kicker">${esc(ev.kicker)}</div>
            <h2 class="ev-title">${esc(ev.title)}</h2>
            <div class="ev-when">${esc(ev.when)}${ev.relative ? ` <span class="muted">· ${esc(ev.relative)}</span>` : ''}</div>
            ${ev.zone ? `<div class="ev-zone">${esc(ev.zone)}</div>` : ''}
            ${ev.repeats ? `<div class="ev-repeats">${esc(ev.repeats)}</div>` : ''}
            ${chips ? `<div class="ev-chips">${chips}</div>` : ''}
            ${(ev.changes || []).length ? `<div class="ev-changes">${ev.changes.map((c) => `<div>${esc(c)}</div>`).join('')}</div>` : ''}
            ${facts || guests ? `<dl class="ev-facts">${facts}${guests}</dl>` : ''}
            ${ev.agenda ? `<div class="ev-agenda">${linkify(esc(ev.agenda))}</div>` : ''}
            ${answers}
            ${ev.footer ? `<div class="ev-foot">${esc(ev.footer)}</div>` : ''}
          </div>`;
        const day = ev.day ? dayHTML(ev.day, ev.dayMessage) : (ev.dayMessage ? `<div class="ev-day"><div class="ev-message">${esc(ev.dayMessage)}</div></div>` : '');
        return `<section class="event-page ${day ? 'with-day' : ''}">${main}${day}</section>`;
      }

      // Your day: an hour grid with your events, the event dashed when it needs an answer, overlaps in red.
      function dayHTML(day, message) {
        const perMinute = 40 / 60;
        const y = (minute) => (minute - day.startMinute) * perMinute;
        const height = Math.max(60, y(day.endMinute));
        let lines = '';
        for (let m = Math.ceil(day.startMinute / 60) * 60; m <= day.endMinute; m += 60) {
          lines += `<span class="ev-hr" style="top:${y(m)}px"></span><span class="ev-hl" style="top:${y(m)}px">${String(Math.floor(m / 60) % 24).padStart(2, '0')}</span>`;
        }
        const blocks = (day.blocks || []).map((b) => {
          const top = y(b.start), h = Math.max(10, y(b.end) - top - 1);
          const width = 100 / b.columns, left = b.column * width;
          const label = h >= 24 && b.columns === 1 ? `${esc(b.time)} ${esc(b.title)}` : esc(b.title);
          return `<span class="ev-blk ${esc(b.kind)} ${h < 16 ? 'thin' : ''}" style="top:${top}px;height:${h}px;left:calc(${left}% + 1px);width:calc(${width}% - 2px)" title="${esc(b.time + ' ' + b.title)}">${label}</span>`;
        }).join('');
        const now = day.nowMinute != null && day.nowMinute >= day.startMinute && day.nowMinute <= day.endMinute ? `<span class="ev-now" style="top:${y(day.nowMinute)}px"></span>` : '';
        return `<div class="ev-day" data-focus="${Math.max(0, y(day.focusMinute) - 60)}">
            <div class="ev-dayhead"><span>${esc(day.title)}${day.peeking ? ' <span class="muted">· another day</span>' : ''}</span>
              <span class="ev-nav"><button data-action="previousDay" title="Day before ({)"><kbd>{</kbd></button><button data-action="nextDay" title="Day after (})"><kbd>}</kbd></button></span></div>
            ${message ? `<div class="ev-message">${esc(message)}</div>` : ''}
            ${(day.allDay || []).length ? `<div class="ev-allday">${day.allDay.map((t) => `<span>${esc(t)}</span>`).join('')}</div>` : ''}
            <div class="ev-grid" style="height:${height}px">${lines}${blocks}${now}</div>
            ${day.note ? `<div class="ev-note ${esc(day.noteKind || '')}">${esc(day.note)}</div>` : ''}
          </div>`;
      }

      // A narrow reader shows the day above the details, scrolled to the event.
      function focusDay() {
        const day = document.querySelector('.ev-day');
        if (day && day.scrollHeight > day.clientHeight + 4) day.scrollTop = Number(day.dataset.focus || 0);
      }

      function render(payload) {
        // An event page that appears or goes starts the view afresh (originals folded, at the top).
        const kept = state && state.threadID && state.threadID === payload.threadID && !!state.event === !!payload.event ? viewState() : null;
        state = payload;
        state.blockedImages = 0;
        document.documentElement.style.colorScheme = payload.dark ? 'dark' : 'light';
        if ((!payload.messages || !payload.messages.length) && payload.event) {
          root.innerHTML = eventPageHTML(payload.event);
          if (payload.showHints) document.body.classList.add('show-hints'); else document.body.classList.remove('show-hints');
          // The same event again (a sync, the clock) stays where it was scrolled to.
          window.scrollTo(0, kept ? kept.scrollY : 0);
          focusDay();
          return;
        }
        if (!payload.messages || !payload.messages.length) {
          root.innerHTML = `<div class="empty">${esc(payload.emptyText || 'Select a message')}</div>`;
          return;
        }
        const multi = payload.messages.length > 1 || !!payload.event;
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
                ${state.labels.map(chipHTML).join('')}
                <span class="time">${payload.messages.length === 1 ? '1 message' : payload.messages.length + ' messages'}${newCount ? ` · ${newCount} new` : ''}</span>
                <div class="position"><span class="count">${esc(state.position)}</span>
                  <button class="nav-button" data-action="previous" ${state.hasPrevious ? '' : 'disabled'}>${icon('chevronLeft', 12)}</button>
                  <button class="nav-button" data-action="next" ${state.hasNext ? '' : 'disabled'}>${icon('chevron', 12)}</button></div>
              </div>` : senderBlock(first, true)}
            ${provenanceHTML()}
            ${payload.nextWith ? `<button class="next-with" data-action="nextWith" title="Show it in the calendar">${icon('calendar', 13)}<span>${esc(payload.nextWith)}</span></button>` : ''}
          </header>`;
        if (payload.event) html += eventPageHTML(payload.event);
        payload.messages.forEach((message, index) => {
          // The original invitation mail starts folded under its event page.
          const expanded = kept && kept.expanded.has(message.id) ? kept.expanded.get(message.id) : (message.expanded && !message.invitation);
          const collapsed = (multi || message.invitation) && !expanded;
          html += `<section class="message ${multi ? 'multi' : ''} ${collapsed ? 'collapsed' : ''} ${message.invitation ? 'invitation-original' : ''}" data-index="${index}" data-id="${esc(message.id)}">`;
          if (multi) {
            const original = message.invitation && payload.event && payload.event.original;
            html += `<div class="message-head" data-toggle-message="${index}">
                <span class="avatar">${esc(message.initials)}</span>
                <span class="name">${esc(original ? '▸ ' + payload.event.original : message.fromName)}</span>
                ${message.isNew ? '<span class="unread-dot"></span>' : ''}
                <span class="snippet">${original ? '' : esc(message.snippet)}</span>
                <span class="when">${original ? '<kbd>O</kbd>' : esc(message.time)}</span>
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
        focusDay();
        window.scrollTo(0, kept ? kept.scrollY : 0);
        if (multi && focused > 0 && !kept && !payload.event) {
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

      function webLink(href) { return /^https?:\/\//i.test(String(href).trim()); }

      document.addEventListener('click', (event) => {
        // A link that would run script in the reader (javascript:, data:, vbscript:) never does.
        const link = event.target.closest('a[href]');
        if (link && /^\s*(javascript|data|vbscript):/i.test(link.getAttribute('href') || '')) { event.preventDefault(); return; }
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
