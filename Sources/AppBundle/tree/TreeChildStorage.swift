import Common

struct TreeChildStorage<Element> {
    private enum Storage {
        case dense([Element])
        case chunked([[Element]])
    }

    private var storage: Storage = .dense([])
    private var totalCount = 0

    var count: Int { totalCount }

    var usesChunks: Bool {
        switch storage {
            case .dense: false
            case .chunked: true
        }
    }

    func children() -> [Element] {
        switch storage {
            case .dense(let children): children
            case .chunked(let chunks): chunks.flatMap { $0 }
        }
    }

    func child(at index: Int) -> Element {
        switch storage {
            case .dense(let children):
                return children[index]
            case .chunked(let chunks):
                let location = locate(index, in: chunks)
                return chunks[location.chunkIndex][location.childIndex]
        }
    }

    func forEachChild(_ body: (Element) -> Void) {
        switch storage {
            case .dense(let children):
                children.forEach(body)
            case .chunked(let chunks):
                chunks.forEach { $0.forEach(body) }
        }
    }

    mutating func insert(_ child: Element, at rawIndex: Int, chunkSize: Int) -> Int {
        let chunkSize = normalize(chunkSize)
        let index = min(max(0, rawIndex), count)
        switch storage {
            case .dense(var children):
                children.insert(child, at: index)
                totalCount += 1
                storage = children.count > chunkSize
                    ? .chunked(makeChunks(from: children, chunkSize: chunkSize))
                    : .dense(children)
            case .chunked(var chunks):
                if totalCount == 0 {
                    chunks = [[child]]
                } else if index == totalCount {
                    chunks[chunks.count - 1].append(child)
                } else {
                    let location = locate(index, in: chunks)
                    chunks[location.chunkIndex].insert(child, at: location.childIndex)
                }
                totalCount += 1
                splitOverflowingChunks(&chunks, chunkSize: chunkSize)
                storage = .chunked(chunks)
        }
        return index
    }

    mutating func remove(at index: Int, chunkSize: Int) -> Element {
        let chunkSize = normalize(chunkSize)
        switch storage {
            case .dense(var children):
                let child = children.remove(at: index)
                totalCount -= 1
                storage = .dense(children)
                return child
            case .chunked(var chunks):
                let location = locate(index, in: chunks)
                let child = chunks[location.chunkIndex].remove(at: location.childIndex)
                totalCount -= 1
                chunks.removeAll(where: \.isEmpty)
                mergeSparseNeighbors(&chunks, chunkSize: chunkSize)
                storage = totalCount <= chunkSize ? .dense(chunks.flatMap { $0 }) : .chunked(chunks)
                return child
        }
    }

    private func locate(_ index: Int, in chunks: [[Element]]) -> (chunkIndex: Int, childIndex: Int) {
        var remaining = index
        for (chunkIndex, chunk) in chunks.enumerated() {
            if remaining < chunk.count {
                return (chunkIndex, remaining)
            }
            remaining -= chunk.count
        }
        die("Index \(index) is out of bounds for chunked storage")
    }

    private func makeChunks(from children: [Element], chunkSize: Int) -> [[Element]] {
        stride(from: 0, to: children.count, by: chunkSize).map {
            Array(children[$0 ..< min($0 + chunkSize, children.count)])
        }
    }

    private func splitOverflowingChunks(_ chunks: inout [[Element]], chunkSize: Int) {
        var chunkIndex = 0
        while chunkIndex < chunks.count {
            if chunks[chunkIndex].count > chunkSize {
                let overflow = Array(chunks[chunkIndex][chunkSize...])
                chunks[chunkIndex].removeSubrange(chunkSize...)
                chunks.insert(overflow, at: chunkIndex + 1)
            }
            chunkIndex += 1
        }
    }

    private func mergeSparseNeighbors(_ chunks: inout [[Element]], chunkSize: Int) {
        var chunkIndex = 0
        while chunkIndex + 1 < chunks.count {
            if chunks[chunkIndex].count + chunks[chunkIndex + 1].count <= chunkSize {
                chunks[chunkIndex].append(contentsOf: chunks.remove(at: chunkIndex + 1))
            } else {
                chunkIndex += 1
            }
        }
    }

    private func normalize(_ chunkSize: Int) -> Int {
        max(2, chunkSize)
    }
}
