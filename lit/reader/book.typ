// The build supplies graph titles and owners to the HTML renderer.
#let registry = json(bytes(sys.inputs.at("lit-registry", default: "{}")))
#let reader = "lit-registry" in sys.inputs

#let reference-text(supplement, title) = {
  if supplement == auto or supplement == [] { title } else { supplement }
}

// In a standalone file, use native labels and leave cross-card resolution to Ospero.
#let card-source(body) = {
  if reader { body } else {
    show ref: it => context {
      let target = query(it.target).at(0, default: none)
      if target == none {
        reference-text(it.supplement, str(it.target))
      } else if target.func() == heading and target.numbering == none {
        link(it.target, reference-text(it.supplement, target.body))
      } else { it }
    }
    body
  }
}

#let card-link(target, supplement) = {
  let id = str(target)
  let entry = registry.at(id, default: (card: id, title: id, block: none))
  let body = reference-text(supplement, entry.title)
  if reader {
    let attrs = (href: "#stack=" + entry.card, "data-card": entry.card)
    if entry.block != none {
      attrs.href += "&block=" + entry.block
      attrs.insert("data-block", entry.block)
    }
    html.elem("a", attrs: attrs, body)
  } else { body }
}

#let card-links(body) = {
  show ref: it => if str(it.target) in registry { card-link(it.target, it.supplement) } else { it }
  body
}

#let include-note(body) = {
  let reference = if body.func() == ref { body } else { body.children.find(it => it.func() == ref) }
  let id = str(reference.target)
  let supplement = reference.fields().at("supplement", default: auto)
  let title = registry.at(id, default: (title: id)).title
  let summary = reference-text(supplement, title)
  if reader {
    html.elem("details", attrs: (class: "tree", "data-embed": id),
      html.elem("summary", summary))
  } else { summary }
}

#let source-index() = {
  if reader {
    let notes = registry.pairs().filter(((id, entry)) => id != "home" and entry.block == none)
    list(..notes.map(((id, entry)) => card-link(label(id), [#raw(id) · #entry.title])))
  }
}

#let chunk(id: none, target: none, noweb: true, body) = {
  if reader {
    html.elem("div", attrs: ("data-lit-chunk": str(id)), [])
  } else { body }
}
