import Foundation

extension PreviewRoutes {
    /// web ターゲットの iframe の sandbox 属性。allow-same-origin / allow-top-navigation は付けない。
    static let webIframeSandbox = "allow-scripts allow-forms allow-popups allow-modals allow-downloads"

    /// The hosted interactive control page, served at GET /preview/ui?s=<session>.
    ///
    /// apiKey はページに一切載せない。載せるのはプレビューのセッション（その表示対象だけに効く）で、
    /// sim は stream の <img> と tap/swipe の fetch に `s=` で付け、web は sandbox の iframe の
    /// パス（/preview/w/<session>/）に入れる。
    static func previewPageHTML(target: PreviewTarget, session: String, aspect: Double? = nil) -> String {
        switch target {
        case .web:
            return webPageHTML(session: session)
        case .sim(let udid):
            return simPageHTML(udid: jsString(udid), sessionLiteral: jsString(session), aspect: aspect)
        }
    }

    /// /preview/ui のページに付ける CSP（自分のパス以外には読み書きさせない）。
    static let pageContentSecurityPolicy =
        "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data: blob:; "
        + "connect-src 'self'; frame-src 'self'; base-uri 'none'; form-action 'none'"

    /// セッションが無い・切れたときの /preview/ui の本文。
    static let expiredPageHTML = """
    <!doctype html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <title>BuddyOS Preview</title>
    <style>html,body{margin:0;height:100%;background:#111;color:#ccc;font-family:-apple-system,sans-serif}
    p{margin:0;padding:32px 24px;text-align:center;line-height:1.6}</style></head>
    <body><p>プレビューを開き直してください。<br>アプリが古い場合は、更新してから開いてください。</p></body></html>
    """

    /// Escape a string for safe embedding inside a single-quoted JS literal.
    private static func jsString(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "<": out += "\\u003C"
            case ">": out += "\\u003E"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static func simPageHTML(udid: String, sessionLiteral: String, aspect: Double? = nil) -> String {
        // 端末の実寸比（width/height）。MJPEG の <img> は naturalWidth/Height が
        // 取れないことがあるため、その場合の fallback として使う。0 = 未指定。
        let arFallback = (aspect.map { $0 > 0 ? $0 : 0 } ?? 0)
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
        <meta name="referrer" content="no-referrer">
        <title>BuddyOS Sim</title>
        <style>
        *{box-sizing:border-box;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}
        html,body{margin:0;background:#000;height:100%;font-family:-apple-system,sans-serif;color:#ccc}
        #wrap{height:100%;display:flex;flex-direction:column;align-items:center}
        #stage{flex:1;display:flex;align-items:center;justify-content:center;width:100%;min-height:0}
        img{max-width:100%;max-height:100%;object-fit:contain;touch-action:none}
        #touch{position:fixed;left:0;top:0;width:40px;height:40px;margin:-20px 0 0 -20px;border-radius:50%;background:rgba(255,255,255,.28);border:1.5px solid rgba(255,255,255,.7);pointer-events:none;opacity:0;transition:opacity .18s}
        #err{position:fixed;left:12px;right:12px;bottom:calc(12px + env(safe-area-inset-bottom));padding:10px 12px;border-radius:10px;background:rgba(40,40,40,.92);color:#eee;font-size:13px;line-height:1.5;text-align:center;pointer-events:none;display:none}
        </style></head>
        <body><div id="wrap">
        <div id="stage"><img id="v" alt="loading…"></div>
        <div id="touch"></div>
        <div id="err"></div>
        </div>
        <script>
        const SESSION='\(sessionLiteral)';
        const UDID='\(udid)';
        const AR_FALLBACK=\(arFallback);
        const qs=(extra)=>'?udid='+encodeURIComponent(UDID)+'&s='+encodeURIComponent(SESSION)+(extra?'&'+extra:'');
        const img=document.getElementById('v');
        img.src='/preview/sim/stream'+qs();
        // Bridge は 20 秒フレームが取れない（sim の起動待ち・停止中）とストリームを閉じる。
        // 壊れた画像のまま残さず付け直す。起動しない UDID に無限に張り直さないよう、
        // 1s→2s→…最大 30s のバックオフで 10 回までにする（表示できたら数え直す）。
        let retry=0,retryTimer=null;
        img.addEventListener('load',()=>{retry=0;});
        img.addEventListener('error',()=>{
          if(retryTimer||retry>=10)return;
          const wait=Math.min(30000,1000*Math.pow(2,retry));retry++;
          retryTimer=setTimeout(()=>{retryTimer=null;img.src='/preview/sim/stream'+qs('_='+Date.now());},wait);
        });
        // 表示画像のアスペクト比。naturalWidth/Height が取れる時はそれを、
        // 取れない（MJPEG ストリーム等）時は bridge 注入の AR_FALLBACK を、
        // それも無ければコンテナ比を使う。これが 0/NaN だとタップ座標が崩れる。
        function imgAspect(r){
          if(img.naturalWidth>0&&img.naturalHeight>0)return img.naturalWidth/img.naturalHeight;
          if(AR_FALLBACK>0)return AR_FALLBACK;
          return r.width/r.height;
        }
        function norm(ev){const r=img.getBoundingClientRect();
          const ar=imgAspect(r), br=r.width/r.height;
          let dw=r.width,dh=r.height,ox=0,oy=0;
          if(br>ar){dw=r.height*ar;ox=(r.width-dw)/2;}else{dh=r.width/ar;oy=(r.height-dh)/2;}
          const x=(ev.clientX-r.left-ox)/dw, y=(ev.clientY-r.top-oy)/dh;
          return {x:Math.max(0,Math.min(1,x)),y:Math.max(0,Math.min(1,y))};}
        // 指の位置に丸を出す（操作が届くまでの間も、押した・なぞった手応えが見えるように）。
        const touch=document.getElementById('touch');
        function showTouch(e){touch.style.transform='translate('+e.clientX+'px,'+e.clientY+'px)';touch.style.opacity='1';}
        // 操作を送る。届かなかったら理由を下に出す（黙って効かないと、映像だけ動いて原因が分からない）。
        const err=document.getElementById('err');let errTimer=null;
        function showErr(msg){err.textContent='操作を送れませんでした: '+msg;err.style.display='block';
          clearTimeout(errTimer);errTimer=setTimeout(()=>{err.style.display='none';},6000);}
        function send(path){fetch(path).then(async r=>{if(!r.ok)showErr((await r.text()).trim().slice(0,200)||('HTTP '+r.status));})
          .catch(()=>showErr('Bridge に届きません'));}
        let down=null,t0=0;
        img.addEventListener('pointerdown',e=>{down=norm(e);t0=Date.now();showTouch(e);try{img.setPointerCapture(e.pointerId);}catch(_){}});
        img.addEventListener('pointermove',e=>{if(down)showTouch(e);});
        img.addEventListener('pointercancel',()=>{down=null;touch.style.opacity='0';});
        img.addEventListener('pointerup',e=>{touch.style.opacity='0';if(!down)return;const up=norm(e);
          const dx=Math.abs(up.x-down.x),dy=Math.abs(up.y-down.y);
          if(dx<0.02&&dy<0.02){send('/preview/sim/tap'+qs('x='+down.x+'&y='+down.y));}
          else{const dur=Math.min(1,(Date.now()-t0)/1000)||0.2;
            send('/preview/sim/swipe'+qs('x1='+down.x+'&y1='+down.y+'&x2='+up.x+'&y2='+up.y+'&d='+dur));}
          down=null;});
        </script></body></html>
        """
    }

    private static func webPageHTML(session: String) -> String {
        // セッションは base64url（英数と - _）だけなので、そのまま属性値に入れてよい。
        let safe = session.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        // 中継したページは sandbox の iframe（allow-same-origin 無し = opaque origin）で開く。
        // 親（このページ。URL に s= がある）・parent.performance・Bridge の他のパスは読めない。
        // allow-top-navigation も付けないので、iframe から上の画面を差し替えられない。
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <title>BuddyOS Web</title>
        <style>
        *{box-sizing:border-box}
        html,body{margin:0;height:100%;background:#fff}
        iframe{border:0;width:100%;height:100%;display:block}
        </style></head>
        <body>
        <iframe src="/preview/w/\(safe)/" sandbox="\(webIframeSandbox)" referrerpolicy="no-referrer"></iframe>
        </body></html>
        """
    }
}
