import Foundation
#if canImport(FoundationXML)
import FoundationXML  // XMLParser, where Foundation does not include it
#endif

/// Just enough XML to read a MusicXML file: a tree of elements, built with Foundation's own parser.
///
/// Written against the shape of tree Python's ElementTree gives — find a child, gather descendants,
/// take an element's text — because the reading was ported from Python code that used it.
enum XMLLite {
    final class Node {
        let name: String
        let attributes: [String: String]
        var text: String = ""
        var children: [Node] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        /// The first child with this name.
        func first(_ name: String) -> Node? {
            children.first { $0.name == name }
        }

        /// Every child with this name.
        func all(_ name: String) -> [Node] {
            children.filter { $0.name == name }
        }

        /// The text of the first child with this name, trimmed, or nil when there is none.
        func firstText(_ name: String) -> String? {
            guard let found = first(name) else { return nil }
            let text = found.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        /// Every element with this name at any depth, this one included: ElementTree's `iter`.
        func descendants(_ name: String) -> [Node] {
            var found: [Node] = []
            var stack: [Node] = [self]
            while let node = stack.popLast() {
                if node.name == name { found.append(node) }
                stack.append(contentsOf: node.children.reversed())
            }
            return found
        }
    }

    enum Failure: Error { case malformed }

    static func parse(_ data: Data) throws -> Node {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // A MusicXML file names a DTD it does not ship, and resolving it would reach for the network
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else { throw Failure.malformed }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = Node(name: name, attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
