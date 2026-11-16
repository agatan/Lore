// Runs only for the English root (`run_worker_first` in wrangler.jsonc); every other path is served straight from site/.
// A first visit is sent to the page in the browser's language. A language picked in the switcher (the `lang` cookie)
// always wins, so a reader who chose English is never bounced back.

const PAGES = { en: null, ja: "/ja/", "zh-Hans": "/zh-Hans/" };

export function chooseLanguage(cookieHeader, acceptLanguage) {
  const chosen = /(?:^|;\s*)lang=([^;]+)/.exec(cookieHeader ?? "")?.[1];
  if (chosen && Object.hasOwn(PAGES, chosen)) return chosen;
  const ranked = (acceptLanguage ?? "")
    .split(",")
    .map((part, index) => {
      const [tag, ...params] = part.trim().split(";");
      const q = Number(params.map((p) => p.trim()).find((p) => p.startsWith("q="))?.slice(2) ?? 1);
      return { tag: tag.toLowerCase(), q: Number.isNaN(q) ? 0 : q, index };
    })
    .filter((entry) => entry.tag && entry.q > 0)
    .sort((a, b) => b.q - a.q || a.index - b.index);
  for (const { tag } of ranked) {
    const supported = supportedLanguage(tag);
    if (supported) return supported;
  }
  return "en";
}

function supportedLanguage(tag) {
  if (tag === "en" || tag.startsWith("en-")) return "en";
  if (tag === "ja" || tag.startsWith("ja-")) return "ja";
  // Traditional Chinese readers are better served by English than by Simplified Chinese.
  if (/^zh(-hans|-cn|-sg|-my)?(-|$)/.test(tag) && !/-(hant|tw|hk|mo)(-|$)/.test(tag)) return "zh-Hans";
  return null;
}

export default {
  async fetch(request, env) {
    const language = chooseLanguage(request.headers.get("Cookie"), request.headers.get("Accept-Language"));
    const target = PAGES[language];
    const response = target
      ? Response.redirect(new URL(target, request.url).toString(), 302)
      : await env.ASSETS.fetch(request);
    const varied = new Response(response.body, response);
    varied.headers.append("Vary", "Accept-Language, Cookie");
    return varied;
  },
};
