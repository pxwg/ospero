const stack = document.querySelector(".zk-stack");
const cards = new Map(Array.from(document.querySelectorAll("template[data-id]"),
  template => [template.dataset.id, template]));
const wide = matchMedia("(min-width: 801px)");
const panes = () => Array.from(stack.children);
const spineWidth = () => parseFloat(getComputedStyle(stack).getPropertyValue("--zk-spine"));

function focusPane(pane) {
  if (!wide.matches) return;
  const all = panes();
  const i = all.indexOf(pane);
  const start = all.slice(0, i).reduce((n, p) => n + p.offsetWidth, 0);
  const lo = start + pane.offsetWidth + (all.length - i - 1) * spineWidth() - stack.clientWidth;
  const hi = start - i * spineWidth();
  stack.scrollLeft = Math.max(0, Math.min(hi, Math.max(lo, stack.scrollLeft)));
}

function layout() {
  const all = panes();
  all.forEach((pane, i) => {
    pane.style.setProperty("--i", i);
    pane.style.setProperty("--n", all.length);
  });
  const left = all.map(p => p.getBoundingClientRect().left);
  all.forEach((pane, i) => {
    const hidden = wide.matches &&
      (left[i + 1] ?? stack.getBoundingClientRect().right) - left[i] < spineWidth() + 80;
    pane.classList.toggle("is-obscured", hidden);
    pane.classList.toggle("is-overlay", wide.matches && i > 0 && left[i] < left[i-1] + all[i-1].offsetWidth - 1);
    pane.querySelector("article").inert = hidden;
    pane.querySelector(".zk-spine").tabIndex = hidden ? 0 : -1;
  });
}

const home = stack.querySelector("article").cloneNode(true);

function loadEmbeds(container, ancestors) {
  container.querySelectorAll("details[data-embed]").forEach(detail => {
    const id = detail.dataset.embed;
    const source = id === "home" ? home : cards.get(id)?.content.firstElementChild;
    if (!source) return;
    if (ancestors.has(id)) {
      const link = document.createElement("a");
      link.href = "#stack=" + id;
      link.dataset.card = id;
      link.textContent = "打开卡片";
      detail.append(link);
      return;
    }
    detail.addEventListener("toggle", () => {
      if (!detail.open || detail.children.length > 1) return;
      const article = source.cloneNode(true);
      article.querySelector("h1")?.remove();
      loadEmbeds(article, new Set([...ancestors, id]));
      detail.append(article);
    });
  });
}

function decorate(pane) {
  loadEmbeds(pane, new Set([pane.dataset.node]));
  const spine = document.createElement("button");
  spine.className = "zk-spine";
  spine.textContent = pane.querySelector("h1").textContent;
  spine.onclick = () => focusPane(pane);
  pane.prepend(spine);
}

function restore() {
  const route = new URLSearchParams(location.hash.slice(1));
  const wanted = ["home", ...new Set((route.get("stack") || "").split(",").filter(id => cards.has(id)))];
  const current = panes();
  let i = 1;
  while (i < wanted.length && current[i]?.dataset.node === wanted[i]) i++;
  current.slice(i).forEach(p => p.remove());
  for (const id of wanted.slice(i)) {
    const pane = document.createElement("section");
    pane.className = "zk-pane";
    pane.dataset.node = id;
    pane.append(cards.get(id).content.cloneNode(true));
    decorate(pane);
    stack.append(pane);
  }
  layout();
  const last = stack.lastElementChild;
  focusPane(last);
  if (!wide.matches) window.scrollTo(0, 0);
  const block = route.get("block");
  if (block) {
    const detail = last.querySelector('details[data-block="' + CSS.escape(block) + '"]');
    if (detail) { detail.open = true; detail.scrollIntoView({block: "nearest"}); }
  }
}

stack.addEventListener("click", event => {
  const link = event.target.closest("a[data-card]");
  if (!link || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  const all = panes();
  const existing = all.find(p => p.dataset.node === link.dataset.card);
  if (wide.matches && existing && !link.dataset.block) { focusPane(existing); return; }
  const origin = all.indexOf(link.closest(".zk-pane"));
  const path = existing ? all.slice(1, all.indexOf(existing) + 1).map(p => p.dataset.node)
    : [...all.slice(1, origin + 1).map(p => p.dataset.node), link.dataset.card];
  const hash = "#stack=" + path.join(",") + (link.dataset.block ? "&block=" + link.dataset.block : "");
  if (location.hash === hash) restore();
  else location.hash = hash;
});
decorate(stack.firstElementChild);
stack.addEventListener("scroll", layout, {passive: true});
window.addEventListener("resize", layout);
window.addEventListener("hashchange", restore);
restore();
