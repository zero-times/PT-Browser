(() => {
  if (window.__ptSniffer) return;
  window.__ptSniffer = true;
  const seen = new Map();
  const known = /\.(jpe?g|png|gif|webp|heic|avif|bmp|tiff?|mp4|m4v|mov|webm|m3u8|mp3|m4a|aac|wav|ogg)(?:[?#]|$)/i;
  let pending = [];
  let timer;
  const clean = text => typeof text === 'string' ? text.replace(/\s+/g, ' ').trim().slice(0, 500) : '';
  const meaningful = text => {
    const value = clean(text);
    return /^(?:play|pause|download|image|photo|video|audio|poster|播放|暂停|下载|图片|视频|音频|封面)(?:\s*\d+)?$/i.test(value) ? '' : value;
  };
  function pageTitle() {
    let doc = document;
    try { if (window.top.document) doc = window.top.document; } catch (_) {}
    return clean(doc.querySelector('meta[property="og:title"]')?.content) || clean(doc.querySelector('meta[name="twitter:title"]')?.content) || clean(doc.title) || clean(doc.querySelector('main h1,article h1,h1')?.textContent);
  }
  function naming(el) {
    const media = el.tagName.toLowerCase() === 'source' ? el.parentElement : el;
    if (!media) return {};
    for (const attribute of ['data-title','title','aria-label','alt']) {
      const title = meaningful(media.getAttribute(attribute));
      if (title) return {title, titlePriority:40};
    }
    const labelled = (media.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => media.ownerDocument.getElementById(id)?.textContent || '').join(' ');
    if (meaningful(labelled)) return {title:meaningful(labelled), titlePriority:40};
    const caption = meaningful(media.closest('figure')?.querySelector('figcaption')?.textContent);
    if (caption) return {title:caption, titlePriority:30};
    const heading = meaningful(media.closest('article,[role="article"]')?.querySelector('h1,h2,h3')?.textContent);
    if (heading) return {title:heading, titlePriority:20};
    if (media.tagName.toLowerCase() === 'a') {
      const text = meaningful(media.textContent);
      if (text) return {title:text, titlePriority:10};
    }
    return {};
  }
  function flush() {
    timer = null;
    window.webkit?.messageHandlers?.media?.postMessage(pending.splice(0, 200));
    if (pending.length) timer = setTimeout(flush, 50);
  }
  function report(raw, kind, source, width, height, mime, info = {}) {
    try {
      if (!raw || typeof raw !== 'string') return;
      const url = new URL(raw, document.baseURI);
      if (!/^https?:$/.test(url.protocol)) return;
      const previous = seen.get(url.href);
      if (!previous && seen.size >= 2000) return;
      const better = info.title && (!previous?.title || (info.titlePriority || 0) >= (previous.titlePriority || 0));
      const encrypted = Boolean(info.encrypted || previous?.encrypted);
      const protection = info.protection || previous?.protection || '';
      const record = {url:url.href, kind:kind || previous?.kind || '', source, width:Math.max(width || 0, previous?.width || 0), height:Math.max(height || 0, previous?.height || 0), mime:mime || previous?.mime || '', page:location.href,
        title:better ? info.title : previous?.title || '', titlePriority:better ? info.titlePriority : previous?.titlePriority || 0, pageTitle:pageTitle(), encrypted, protection};
      if (previous && ['width','height','kind','mime','title','titlePriority','pageTitle','encrypted','protection'].every(key => previous[key] === record[key])) return;
      seen.set(url.href, record);
      pending.push(record);
      if (!timer) timer = setTimeout(flush, 180);
    } catch (_) {}
  }
  const encryptedURL = /(?:widevine|playready|fairplay|clearkey|drmtoken|getlicense|skd:)/i;
  function playlistProtection(text) {
    const line = String(text || '').match(/#EXT-X-KEY:([^\n\r]*)/i);
    if (!line || /METHOD=NONE/i.test(line[1])) return '';
    if (/METHOD=AES-128/i.test(line[1])) return 'HLS 使用 AES-128 加密，密钥过期后可能无法再查看，请尽快下载。';
    if (/SAMPLE-AES|ISO-23001-7/i.test(line[1])) return 'HLS 使用样本加密，密钥过期后可能无法再查看，请尽快下载。';
    return '播放列表包含加密密钥，过期后可能无法再查看，请尽快下载。';
  }
  function protectionFor(url) {
    if (!encryptedURL.test(url)) return '';
    return '地址指向加密或授权服务，密钥过期后可能无法再查看，请尽快下载。';
  }
  function resource(url, mime, source, info) {
    let kind = /^image\//i.test(mime) ? 'image' : /^audio\//i.test(mime) ? 'audio' : (/^video\//i.test(mime) || /mpegurl|dash\+xml/i.test(mime)) ? 'video' : '';
    const extra = {...(info || {})};
    const protection = extra.protection || protectionFor(url);
    if (protection) { extra.encrypted = true; extra.protection = protection; }
    if (kind || known.test(url) || /\.mpd(?:[?#]|$)/i.test(url)) report(url, kind, source, 0, 0, mime, extra);
  }
  function inspectPlaylist(response) {
    const type = response.headers?.get?.('content-type') || '';
    const url = response.url || '';
    if (!/mpegurl/i.test(type) && !/\.m3u8(?:[?#]|$)/i.test(url)) return;
    response.clone().text().then(text => {
      const protection = playlistProtection(text);
      if (protection) report(url, 'video', '播放列表', 0, 0, type, {encrypted:true, protection});
    }).catch(() => {});
  }
  const originalFetch = window.fetch;
  window.fetch = function(...args) {
    return originalFetch.apply(this,args).then(response => {
      resource(response.url, response.headers.get('content-type') || '', 'fetch');
      inspectPlaylist(response);
      return response;
    });
  };
  const open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(...args) {
    this.addEventListener('load', () => {
      let type = '';
      try { type = this.getResponseHeader('content-type') || ''; } catch (_) {}
      resource(this.responseURL, type, 'XHR');
      try {
        if ((/mpegurl/i.test(type) || /\.m3u8(?:[?#]|$)/i.test(this.responseURL || '')) && typeof this.responseText === 'string') {
          const protection = playlistProtection(this.responseText);
          if (protection) report(this.responseURL, 'video', '播放列表', 0, 0, type, {encrypted:true, protection});
        }
      } catch (_) {}
    });
    return open.apply(this,args);
  };
  function scan(root = document) {
    root.querySelectorAll('img,video,audio,source,a,[style],meta[property="og:image"],meta[property="og:video"]').forEach(el => {
      const tag = el.tagName.toLowerCase();
      const kind = tag === 'img' ? 'image' : tag === 'video' ? 'video' : tag === 'audio' ? 'audio' : el.parentElement?.tagName.toLowerCase() === 'video' ? 'video' : '';
      const info = naming(el);
      if (['img','video','audio','source'].includes(tag)) {
        [el.currentSrc,el.src,el.dataset.src,el.dataset.original].filter(Boolean).forEach(url => report(url,kind,'页面元素',el.naturalWidth || el.videoWidth,el.naturalHeight || el.videoHeight,el.type,info));
        if (el.srcset) el.srcset.split(',').forEach(part => report(part.trim().split(/\s+/)[0],kind,'srcset',0,0,'',info));
        if (el.poster) report(el.poster,'image','视频封面',0,0,'',info);
      }
      if (tag === 'a' && known.test(el.href)) resource(el.href,'','资源链接',info);
      if (tag === 'meta' && el.content) report(el.content,el.getAttribute('property') === 'og:image' ? 'image' : 'video','Open Graph');
      if (el.style?.backgroundImage) {
        [...el.style.backgroundImage.matchAll(/url\(["']?([^"')]+)["']?\)/g)].forEach(match => report(match[1],'image','背景图片',0,0,'',info));
      }
    });
    root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) scan(el.shadowRoot); });
    performance.getEntriesByType('resource').forEach(entry => resource(entry.name,'','网络资源'));
  }
  window.__ptScan = () => { seen.clear(); scan(); };
  let debounce;
  function start() {
    scan();
    new MutationObserver(() => { clearTimeout(debounce); debounce = setTimeout(() => scan(), 600); }).observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['src','srcset','style','data-src','data-title','title','alt','aria-label','aria-labelledby','content']});
    document.addEventListener('loadedmetadata', () => scan(), true);
    document.addEventListener('encrypted', event => {
      const media = event.target;
      const url = media?.currentSrc || media?.src;
      if (url) report(url, media?.tagName?.toLowerCase() === 'audio' ? 'audio' : 'video', '加密媒体', media?.videoWidth || 0, media?.videoHeight || 0, '', {...naming(media), encrypted:true, protection:'网页正在使用加密播放，密钥过期后可能无法再查看，请尽快下载。'});
    }, true);
    if (window.HTMLMediaElement) {
      const setMediaKeys = HTMLMediaElement.prototype.setMediaKeys;
      if (setMediaKeys) HTMLMediaElement.prototype.setMediaKeys = function(keys) {
        if (keys) {
          const url = this.currentSrc || this.src;
          if (url) report(url, this.tagName.toLowerCase() === 'audio' ? 'audio' : 'video', '加密媒体', this.videoWidth || 0, this.videoHeight || 0, '', {...naming(this), encrypted:true, protection:'网页已绑定 DRM 密钥，过期后可能无法再查看，请尽快下载。'});
        }
        return setMediaKeys.apply(this, arguments);
      };
    }
    document.addEventListener('load', e => { if (e.target instanceof HTMLImageElement) scan(); }, true);
    try { new PerformanceObserver(list => list.getEntries().forEach(e => resource(e.name,'','网络资源'))).observe({entryTypes:['resource']}); } catch (_) {}
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded',start); else start();
})();
