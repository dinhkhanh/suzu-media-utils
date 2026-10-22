import Foundation

/// HTML for the web gallery, shared by the static export and the local-network server.
enum GalleryHTML {
    struct PersonCard { var name: String; var photos: Int; var videos: Int; var cover: String; var link: String }
    struct Tile { var thumb: String; var view: String; var download: String; var isVideo: Bool; var caption: String }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static let style = """
        <style>
        :root{color-scheme:light dark;--bg:#f6f6f7;--fg:#1c1c1e;--muted:#6e6e73;--card:#fff;--accent:#e2475d}
        @media (prefers-color-scheme:dark){:root{--bg:#141416;--fg:#f2f2f7;--muted:#98989d;--card:#1f1f22}}
        *{box-sizing:border-box}body{margin:0;font:15px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--fg)}
        header{padding:20px 16px 8px;max-width:1400px;margin:auto}h1{margin:0 0 4px;font-size:24px}.muted{color:var(--muted)}
        a{color:inherit;text-decoration:none}main{max-width:1400px;margin:auto;padding:8px 16px 40px}
        .people{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:18px}
        .person{text-align:center}.person img{width:120px;height:120px;border-radius:50%;object-fit:cover;background:#8884}
        .person b{display:block;margin-top:6px}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:6px}
        .tile{position:relative;aspect-ratio:1;overflow:hidden;border-radius:6px;background:#8883;cursor:zoom-in}
        .tile img{width:100%;height:100%;object-fit:cover}.play{position:absolute;inset:0;display:grid;place-items:center;font-size:44px;color:#fff;text-shadow:0 2px 8px #000a}
        #lb{position:fixed;inset:0;background:#000e;display:none;align-items:center;justify-content:center;z-index:9}
        #lb.on{display:flex}#lb img,#lb video{max-width:96vw;max-height:86vh}#lb nav{position:fixed;bottom:14px;display:flex;gap:10px}
        #lb nav a,#lb nav button{background:#fff2;color:#fff;border:0;border-radius:8px;padding:8px 14px;font:inherit;cursor:pointer}
        form.rename{display:inline-flex;gap:6px;margin-top:8px}form.rename input{font:inherit;padding:6px 8px;border-radius:6px;border:1px solid #8886;background:var(--card);color:var(--fg)}
        form.rename button{font:inherit;padding:6px 12px;border:0;border-radius:6px;background:var(--accent);color:#fff}
        </style>
        """

    static let lightbox = """
        <div id="lb"><div id="lbc"></div><nav><button onclick="go(-1)">‹ Prev</button><a id="dl" href="#" download>Download</a><button onclick="go(1)">Next ›</button><button onclick="lb.classList.remove('on')">Close</button></nav></div>
        <script>
        const tiles=[...document.querySelectorAll('.tile')];let cur=0;const lb=document.getElementById('lb'),c=document.getElementById('lbc'),dl=document.getElementById('dl');
        function show(i){cur=(i+tiles.length)%tiles.length;const t=tiles[cur].dataset;c.innerHTML=t.video?`<video src="${t.view}" controls autoplay></video>`:`<img src="${t.view}">`;dl.href=t.dl;lb.classList.add('on')}
        function go(d){show(cur+d)}tiles.forEach((t,i)=>t.onclick=()=>show(i));
        document.onkeydown=e=>{if(!lb.classList.contains('on'))return;if(e.key=='ArrowRight')go(1);if(e.key=='ArrowLeft')go(-1);if(e.key=='Escape')lb.classList.remove('on')};
        lb.onclick=e=>{if(e.target==lb)lb.classList.remove('on')};
        </script>
        """

    static func page(_ title: String, subtitle: String, body: String) -> String {
        """
        <!doctype html><html lang="vi"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(title))</title>\(style)</head><body><header><h1>\(escape(title))</h1><div class="muted">\(subtitle)</div></header>
        <main>\(body)</main></body></html>
        """
    }

    static func people(_ title: String, _ cards: [PersonCard]) -> String {
        let items = cards.map { c in
            "<a class=\"person\" href=\"\(c.link)\"><img loading=\"lazy\" src=\"\(c.cover)\" alt=\"\"><b>\(escape(c.name))</b><span class=\"muted\">\(c.photos) photos\(c.videos > 0 ? " · \(c.videos) videos" : "")</span></a>"
        }.joined()
        return page(title, subtitle: "\(cards.count) people", body: "<div class=\"people\">\(items)</div>")
    }

    static func person(_ name: String, back: String, tiles: [Tile], renameAction: String? = nil) -> String {
        let grid = tiles.map { t in
            "<div class=\"tile\" data-view=\"\(t.view)\" data-dl=\"\(t.download)\"\(t.isVideo ? " data-video=\"1\"" : "") title=\"\(escape(t.caption))\"><img loading=\"lazy\" src=\"\(t.thumb)\" alt=\"\">\(t.isVideo ? "<div class=\"play\">▶</div>" : "")</div>"
        }.joined()
        let rename = renameAction.map {
            "<form class=\"rename\" method=\"post\" action=\"\($0)\"><input name=\"name\" value=\"\(escape(name))\" placeholder=\"Name\"><button>Save name</button></form>"
        } ?? ""
        return page(name, subtitle: "<a href=\"\(back)\">‹ All people</a> · \(tiles.count) files \(rename)", body: "<div class=\"grid\">\(grid)</div>\(lightbox)")
    }
}
