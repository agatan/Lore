// TOC のスクロールスパイ: 表示中のセクションに対応するリンクをハイライトする
const tocLinks = Array.from(document.querySelectorAll("#toc a"));
const sections = tocLinks
  .map((a) => document.querySelector(a.getAttribute("href")))
  .filter(Boolean);

const observer = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      const id = entry.target.id;
      tocLinks.forEach((a) =>
        a.classList.toggle("active", a.getAttribute("href") === `#${id}`)
      );
    }
  },
  { rootMargin: "-20% 0px -70% 0px" }
);
sections.forEach((s) => observer.observe(s));
