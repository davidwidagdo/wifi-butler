import Cocoa

// Wraps content in a Liquid Glass panel (macOS 26+); for chrome, not dense text.
enum GlassPanel {
    static func wrap(_ content: NSView, cornerRadius: CGFloat = 14, padding: CGFloat = 10) -> NSView {
        let glass = NSGlassEffectView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }

        let holder = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -padding),
        ])

        // Assign first: AppKit adopts contentView as its own subview.
        glass.contentView = holder
        holder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: glass.topAnchor),
            holder.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            holder.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
        ])
        return glass
    }
}
