/* NewsBar reader-mode extractor.
 *
 * Runs on demand in the reader's isolated content world. It never modifies the
 * live page: every candidate is cloned before noise removal. The payload is
 * plain text plus a few image URLs — no HTML crosses the bridge, so the native
 * reader cannot be used as an HTML injection surface.
 *
 * Contract (posted to window.webkit.messageHandlers.readerMode):
 * { token, url, payload: { ok, reason, url, title, byline, siteName,
 *   publishedAt, lang, wordCount, score, selector,
 *   blocks: [{ type, text?, items?, src?, alt?, caption?, href? }] } }
 */
(() => {
  const TOKEN = window.__newsbarReaderModeToken || "";
  const MAX_BLOCKS = 500;
  const MAX_BLOCK_TEXT = 8000;
  const MAX_LIST_ITEMS = 50;
  const MAX_LATIN_BLOCK = 4000;

  const result = {
    ok: false,
    reason: null,
    url: location.href,
    title: "",
    byline: null,
    siteName: null,
    publishedAt: null,
    lang: null,
    wordCount: 0,
    score: 0,
    selector: null,
    blocks: [],
  };

  const clean = (value) =>
    String(value == null ? "" : value)
      .replace(/\u00a0/g, " ")
      .replace(/[\u200b-\u200f\ufeff]/g, "")
      .replace(/[ \t\r\f\v]+/g, " ")
      .replace(/\n{2,}/g, "\n")
      .trim();

  const absoluteUrl = (raw) => {
    if (!raw) return null;
    try {
      const url = new URL(String(raw).trim(), location.href);
      return url.protocol === "https:" ? url.href : null;
    } catch (error) {
      return null;
    }
  };

  const metaContent = (selector) => {
    const el = document.querySelector(selector);
    const value = el && el.getAttribute("content");
    return value ? clean(value) : null;
  };

  const bestImage = (img) => {
    if (!img) return null;
    const srcset = img.getAttribute("srcset") || img.getAttribute("data-srcset");
    if (srcset) {
      let best = null;
      let bestWidth = -1;
      for (const part of srcset.split(",")) {
        const bits = part.trim().split(/\s+/);
        if (!bits[0]) continue;
        const width = bits[1] && bits[1].endsWith("w") ? parseFloat(bits[1]) : 0;
        if (width > bestWidth) {
          bestWidth = width;
          best = bits[0];
        }
      }
      const resolved = absoluteUrl(best);
      if (resolved) return resolved;
    }
    return absoluteUrl(
      img.getAttribute("data-src") ||
        img.getAttribute("data-original") ||
        img.getAttribute("data-lazy-src") ||
        img.getAttribute("src")
    );
  };

  // A comment avatar is 32x32. Stretched to the reading column it becomes a
  // black smear, which is exactly what readers reported. Only images that are
  // demonstrably content-sized become figures.
  const MIN_IMAGE_WIDTH = 240;
  const MIN_IMAGE_HEIGHT = 160;
  const DECORATIVE_SRC = /(^|[/_.-])(avatar|icon|logo|emoji|sprite|gravatar)([/_.-]|$)/;

  const isDecorativeImage = (img, caption) => {
    const hasCaption = !!(caption && caption.trim());
    const width = img.naturalWidth || Number(img.getAttribute("width")) || 0;
    const height = img.naturalHeight || Number(img.getAttribute("height")) || 0;
    // No size and no caption: the page has not marked this as content.
    if (!hasCaption && (!width || !height)) return true;
    if (width && height && (width < MIN_IMAGE_WIDTH || height < MIN_IMAGE_HEIGHT)) return true;
    const role = (img.getAttribute("role") || "").toLowerCase();
    if (role === "presentation" || role === "none") return true;
    const alt = (img.getAttribute("alt") || "").toLowerCase();
    if (/(avatar|icon|logo|emoji|badge|sprite)/.test(alt)) return true;
    const src = (img.currentSrc || img.getAttribute("src") || "").toLowerCase();
    if (DECORATIVE_SRC.test(src)) return true;
    return !!img.closest(
      'a[href*="/user"], a[href*="/profile"], a[rel~="author"], ' +
      '[class*="avatar" i], [class*="comment" i], [class*="discussion" i]'
    );
  };

  const NOISE = [
    "script", "style", "noscript", "iframe", "svg", "canvas", "video", "audio",
    "form", "input", "select", "textarea", "button", "nav", "footer", "aside",
    "header", "[role=navigation]", "[role=banner]", "[role=complementary]",
    ".comment", ".comments", ".sidebar", ".footer", ".nav", ".share", ".shared",
    ".related", ".advert", ".ads", ".ad", ".recommend", ".recommended",
    "[class*=avatar i]", "[class*=discussion i]", "[data-testid*=comment i]",
    "[itemprop=comment]", "#comments", "#sidebar", "#footer", "#nav",
  ].join(",");

  const NEGATIVE = [
    "comment", "sidebar", "footer", "nav", "share", "related", "advert",
    "recommend", "promo", "subscribe", "newsletter", "cookie", "popup",
  ];

  const stripNoise = (root) => {
    try {
      for (const el of Array.from(root.querySelectorAll(NOISE))) el.remove();
    } catch (error) {
      /* a malformed subtree is skipped rather than failing the extraction */
    }
  };

  const scoreCandidate = (element) => {
    const tag = element.tagName.toLowerCase();
    let weight = 0.9;
    if (tag === "article") weight = 1.2;
    else if (tag === "main") weight = 1.15;
    else if (element.getAttribute("role") === "main") weight = 1.15;
    else if (/(^|[\s_-])(post|entry-content|article-body)([\s_-]|$)/i.test(element.className || "")) weight = 1.1;
    else if (element.id === "content" || element.id === "main") weight = 1.05;

    let paragraphText = 0;
    let paragraphCount = 0;
    for (const paragraph of element.querySelectorAll("p")) {
      const length = Math.min(800, clean(paragraph.textContent).length);
      paragraphText += length;
      if (length >= 20) paragraphCount += 1;
    }
    const total = Math.max(1, clean(element.textContent).length);
    let linkText = 0;
    for (const anchor of element.querySelectorAll("a")) linkText += clean(anchor.textContent).length;
    const linkDensity = Math.min(1, linkText / total);

    const className = ((element.className || "") + " " + (element.id || "")).toLowerCase();
    let penalty = 0;
    for (const word of NEGATIVE) if (className.indexOf(word) >= 0) penalty += 600;

    return paragraphText * weight + paragraphCount * 30 - linkDensity * paragraphText * 1.4 - penalty;
  };

  const OVERRIDES = [
    ["ithome.com", "#paragraph"],
    ["sspai.com", "article"],
    ["arstechnica.com", "article"],
    ["bbc.com", "article"],
    ["theguardian.com", "article"],
  ];

  const findRoot = () => {
    const host = location.hostname.replace(/^www\./, "");
    for (const entry of OVERRIDES) {
      const domain = entry[0];
      const selector = entry[1];
      if (host !== domain && !host.endsWith("." + domain)) continue;
      try {
        const element = document.querySelector(selector);
        if (element && clean(element.textContent).length >= 400) {
          return { element, selector, score: scoreCandidate(element) };
        }
      } catch (error) {
        /* an invalid override selector falls through to the heuristic */
      }
    }

    const candidates = [];
    const seen = new Set();
    const add = (element) => {
      if (!element || seen.has(element)) return;
      seen.add(element);
      candidates.push(element);
    };
    for (const selector of ["article", "main", "[role=main]", ".post", ".entry-content", "#content"]) {
      for (const element of document.querySelectorAll(selector)) add(element);
    }
    let inspected = 0;
    for (const div of document.querySelectorAll("div")) {
      if (inspected >= 400) break;
      inspected += 1;
      if (div.querySelectorAll("p").length >= 4) add(div);
    }

    let best = null;
    let bestScore = -Infinity;
    for (const element of candidates) {
      const score = scoreCandidate(element);
      if (score > bestScore) {
        bestScore = score;
        best = element;
      }
    }
    if (best && bestScore >= 900 && clean(best.textContent).length >= 400) {
      return { element: best, selector: "heuristic", score: bestScore };
    }

    const body = document.body;
    if (!body) return { element: null, selector: null, score: 0 };
    return { element: body, selector: "body", score: bestScore === -Infinity ? 0 : bestScore };
  };

  const extractBlocks = (root) => {
    const blocks = [];
    const handled = new Set();
    const push = (block) => {
      if (blocks.length >= MAX_BLOCKS) return;
      blocks.push(block);
    };
    const imageBlock = (img, caption) => {
      if (isDecorativeImage(img, caption)) return false;
      const src = bestImage(img);
      if (!src) return false;
      handled.add(img);
      push({
        type: "figure",
        src,
        alt: clean(img.getAttribute("alt") || ""),
        caption: caption || undefined,
      });
      return true;
    };

    const walk = (node) => {
      if (!node || blocks.length >= MAX_BLOCKS) return;
      if (node.nodeType !== 1) return;
      if (handled.has(node)) return;
      const tag = node.tagName.toLowerCase();

      if (tag === "figure") {
        const img = node.querySelector("img");
        const figcaption = node.querySelector("figcaption");
        const caption = clean(figcaption ? figcaption.textContent : "").slice(0, 300);
        if (img && imageBlock(img, caption)) return;
        if (caption) {
          push({ type: "p", text: caption });
          return;
        }
      }

      if (tag === "img") {
        if (imageBlock(node, "")) return;
      }

      if (tag === "h2" || tag === "h3" || tag === "h4") {
        const text = clean(node.textContent);
        if (text && text.length <= 300) push({ type: tag === "h2" ? "h2" : "h3", text });
        return;
      }

      if (tag === "p") {
        const text = clean(node.textContent);
        if (text.length >= 2) {
          const item = { type: "p", text: text.slice(0, MAX_BLOCK_TEXT) };
          const links = node.querySelectorAll("a");
          if (links.length === 1 && clean(links[0].textContent) === text) {
            const href = absoluteUrl(links[0].getAttribute("href"));
            if (href) item.href = href;
          }
          push(item);
          return;
        }
        const img = node.querySelector("img");
        if (img && imageBlock(img, "")) return;
        return;
      }

      if (tag === "ul" || tag === "ol") {
        const items = [];
        for (const child of Array.from(node.children)) {
          if (!child.tagName || child.tagName.toLowerCase() !== "li") continue;
          const text = clean(child.textContent);
          if (text.length >= 1) items.push(text.slice(0, 1000));
          if (items.length >= MAX_LIST_ITEMS) break;
        }
        if (items.length) push({ type: tag, items });
        return;
      }

      if (tag === "blockquote") {
        const text = clean(node.textContent);
        if (text) push({ type: "quote", text: text.slice(0, MAX_BLOCK_TEXT) });
        return;
      }

      if (tag === "pre") {
        const text = clean(node.textContent);
        if (text) push({ type: "pre", text: text.slice(0, MAX_BLOCK_TEXT) });
        return;
      }

      if (tag === "hr") {
        push({ type: "hr" });
        return;
      }

      for (const child of Array.from(node.childNodes)) walk(child);
    };

    walk(root);
    return blocks;
  };

  try {
    result.title = clean(
      metaContent('meta[property="og:title"]') || document.title || ""
    ).slice(0, 300);
    result.byline = (metaContent('meta[name="author"]') || metaContent('meta[property="article:author"]') || "").slice(0, 200) || null;
    result.siteName = (metaContent('meta[property="og:site_name"]') || "").slice(0, 200) || null;
    result.publishedAt = (metaContent('meta[property="article:published_time"]') || "").slice(0, 64) || null;
    if (!result.publishedAt) {
      const time = document.querySelector("time[datetime]");
      if (time) result.publishedAt = clean(time.getAttribute("datetime")).slice(0, 64);
    }
    result.lang = document.documentElement && document.documentElement.lang
      ? clean(document.documentElement.lang).slice(0, 16)
      : null;

    const found = findRoot();
    result.selector = found.selector;
    result.score = Math.round(found.score);
    if (!found.element) {
      result.reason = "no_body";
    } else {
      const clone = found.element.cloneNode(true);
      if (!clone || !clone.querySelectorAll) throw new Error("clone failed");
      stripNoise(clone);
      result.blocks = extractBlocks(clone);
    }

    let text = "";
    for (const block of result.blocks) {
      if (block.text) text += block.text + "\n";
      if (block.items) text += block.items.join("\n") + "\n";
      if (block.caption) text += block.caption + "\n";
    }
    const compactLength = text.replace(/\s/g, "").length;
    const cjk = (text.match(/[\u3400-\u9fff\uf900-\ufaff]/g) || []).length;
    const latin = (text.match(/[A-Za-z0-9]+/g) || []).length;
    result.wordCount = cjk + latin;

    const textual = result.blocks.filter(
      (block) => block.type !== "img" && block.type !== "figure" && block.type !== "hr"
    ).length;
    if (found.element && compactLength >= 400 && textual >= 3) {
      result.ok = true;
    } else {
      result.reason = found.element ? "too_short" : result.reason || "no_body";
      result.ok = false;
    }
  } catch (error) {
    result.ok = false;
    result.reason = "script_error";
    result.blocks = [];
  }

  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.readerMode) {
    window.webkit.messageHandlers.readerMode.postMessage({
      token: TOKEN,
      url: location.href,
      payload: result,
    });
  }
})();
