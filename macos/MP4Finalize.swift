import Foundation

// Extend the final video sample when an Android encoder stops emitting frames
// on a static screen. Only the small trailing moov atom is rewritten; mdat and
// all encoded video/audio bytes remain untouched. No external FFmpeg is needed.
private struct MP4Atom {
    var type: String
    var body: Data
    var encoded: Data {
        var bytes = Data()
        bytes.appendBE(UInt64(body.count + 8), count: 4)
        bytes.append(Data(type.utf8)); bytes.append(body)
        return bytes
    }
}
private extension Data {
    func be(_ offset: Int, _ count: Int) throws -> UInt64 {
        guard offset >= 0, offset + count <= self.count else { throw MP4Error.invalid }
        return self[offset..<(offset+count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    mutating func appendBE(_ value: UInt64, count: Int) {
        for index in (0..<count).reversed() { append(UInt8(truncatingIfNeeded: value >> (index*8))) }
    }
    mutating func putBE(_ value: UInt64, at offset: Int, count: Int) throws {
        guard offset >= 0, offset+count <= self.count,
              count == 8 || value <= UInt64(UInt32.max) else { throw MP4Error.invalid }
        var replacement = Data(); replacement.appendBE(value, count: count)
        replaceSubrange(offset..<(offset+count), with: replacement)
    }
}
private enum MP4Error: Error { case invalid, unsupportedLayout }
private func atoms(_ data: Data) throws -> [MP4Atom] {
    var result: [MP4Atom] = []; var offset = 0
    while offset < data.count {
        let size = Int(try data.be(offset, 4))
        guard size >= 8, offset+size <= data.count,
              let name = String(data: data.subdata(in: (offset+4)..<(offset+8)), encoding: .ascii) else { throw MP4Error.invalid }
        result.append(MP4Atom(type: name, body: data.subdata(in: (offset+8)..<(offset+size))))
        offset += size
    }
    return result
}
private func joined(_ atoms: [MP4Atom]) -> Data { atoms.reduce(into: Data()) { $0.append($1.encoded) } }
private func timing(_ data: Data) throws -> (scale: UInt64, duration: UInt64, offset: Int, count: Int) {
    let version = try data.be(0, 1)
    let scaleOffset = version == 1 ? 20 : 12
    let durationOffset = version == 1 ? 24 : 16
    let count = version == 1 ? 8 : 4
    return (try data.be(scaleOffset, 4), try data.be(durationOffset, count), durationOffset, count)
}
private func extendVideoTrack(_ atom: MP4Atom, movieScale: UInt64, target: UInt64) throws -> MP4Atom {
    var track = try atoms(atom.body)
    guard let mediaIndex = track.firstIndex(where: { $0.type == "mdia" }),
          let headerIndex = track.firstIndex(where: { $0.type == "tkhd" }) else { return atom }
    var media = try atoms(track[mediaIndex].body)
    guard let handler = media.first(where: { $0.type == "hdlr" }), handler.body.count >= 12,
          String(data: handler.body.subdata(in: 8..<12), encoding: .ascii) == "vide",
          let mdhdIndex = media.firstIndex(where: { $0.type == "mdhd" }),
          let minfIndex = media.firstIndex(where: { $0.type == "minf" }) else { return atom }
    let headerVersion = try track[headerIndex].body.be(0, 1)
    let headerOffset = headerVersion == 1 ? 28 : 20
    let headerCount = headerVersion == 1 ? 8 : 4
    let old = try track[headerIndex].body.be(headerOffset, headerCount)
    guard target > old else { return atom }
    let delta = target - old
    let time = try timing(media[mdhdIndex].body)
    guard movieScale > 0, time.scale > 0 else { throw MP4Error.invalid }
    let mediaDelta = UInt64((Double(delta)*Double(time.scale)/Double(movieScale)).rounded())
    var minf = try atoms(media[minfIndex].body)
    guard let stblIndex = minf.firstIndex(where: { $0.type == "stbl" }) else { throw MP4Error.invalid }
    var stbl = try atoms(minf[stblIndex].body)
    guard let sttsIndex = stbl.firstIndex(where: { $0.type == "stts" }) else { throw MP4Error.invalid }
    var stts = stbl[sttsIndex].body
    let entries = Int(try stts.be(4, 4))
    guard entries > 0, stts.count == 8+entries*8 else { throw MP4Error.invalid }
    let last = 8+(entries-1)*8
    let count = try stts.be(last, 4)
    let duration = try stts.be(last+4, 4)
    guard count > 0, duration + mediaDelta <= UInt64(UInt32.max) else { throw MP4Error.invalid }
    if count == 1 { try stts.putBE(duration+mediaDelta, at: last+4, count: 4) }
    else {
        try stts.putBE(count-1, at: last, count: 4)
        try stts.putBE(UInt64(entries+1), at: 4, count: 4)
        stts.appendBE(1, count: 4); stts.appendBE(duration+mediaDelta, count: 4)
    }
    stbl[sttsIndex].body = stts
    minf[stblIndex].body = joined(stbl); media[minfIndex].body = joined(minf)
    try media[mdhdIndex].body.putBE(time.duration+mediaDelta, at: time.offset, count: time.count)
    track[mediaIndex].body = joined(media)
    try track[headerIndex].body.putBE(target, at: headerOffset, count: headerCount)
    if let editIndex = track.firstIndex(where: { $0.type == "edts" }) {
        var edits = try atoms(track[editIndex].body)
        if let listIndex = edits.firstIndex(where: { $0.type == "elst" }) {
            let version = try edits[listIndex].body.be(0, 1)
            let entryCount = Int(try edits[listIndex].body.be(4, 4))
            let stride = version == 1 ? 20 : 12
            let bytes = version == 1 ? 8 : 4
            guard entryCount > 0 else { throw MP4Error.invalid }
            let offset = 8+(entryCount-1)*stride
            let value = try edits[listIndex].body.be(offset, bytes)
            try edits[listIndex].body.putBE(value+delta, at: offset, count: bytes)
            track[editIndex].body = joined(edits)
        }
    }
    return MP4Atom(type: atom.type, body: joined(track))
}
func finalizeMP4(_ url: URL, elapsed: TimeInterval) throws {
    guard elapsed >= 1 else { return }
    let file = try FileHandle(forUpdating: url); defer { try? file.close() }
    let fileSize = try file.seekToEnd()
    var offset: UInt64 = 0; var moovOffset: UInt64?; var moovLength: UInt64 = 0
    var lastMediaEnd: UInt64 = 0
    while offset+8 <= fileSize {
        try file.seek(toOffset: offset)
        guard let header = try file.read(upToCount: 16), header.count >= 8 else { throw MP4Error.invalid }
        var length = try header.be(0, 4)
        let type = String(data: header.subdata(in: 4..<8), encoding: .ascii)
        if length == 1 { length = try header.be(8, 8) }
        if length == 0 { length = fileSize-offset }
        guard length >= 8, offset+length <= fileSize else { throw MP4Error.invalid }
        if type == "moov" { moovOffset = offset; moovLength = length }
        if type == "mdat" { lastMediaEnd = offset+length }
        offset += length
    }
    guard let moovOffset = moovOffset, lastMediaEnd <= moovOffset,
          fileSize-moovOffset <= 64*1024*1024 else { throw MP4Error.unsupportedLayout }
    try file.seek(toOffset: moovOffset)
    guard let original = try file.readToEnd(), original.count >= Int(moovLength) else { throw MP4Error.invalid }
    var root = try atoms(original)
    guard let rootIndex = root.firstIndex(where: { $0.type == "moov" }) else { throw MP4Error.invalid }
    var movie = try atoms(root[rootIndex].body)
    guard let headerIndex = movie.firstIndex(where: { $0.type == "mvhd" }) else { throw MP4Error.invalid }
    let time = try timing(movie[headerIndex].body)
    guard time.scale > 0 else { throw MP4Error.invalid }
    let target = UInt64((elapsed*Double(time.scale)).rounded())
    guard Double(target)-Double(time.duration) > Double(time.scale)*0.8 else { return }
    for index in movie.indices where movie[index].type == "trak" {
        movie[index] = try extendVideoTrack(movie[index], movieScale: time.scale, target: target)
    }
    try movie[headerIndex].body.putBE(target, at: time.offset, count: time.count)
    root[rootIndex].body = joined(movie)
    let updated = joined(root)
    do {
        try file.seek(toOffset: moovOffset); try file.write(contentsOf: updated)
        try file.truncate(atOffset: moovOffset+UInt64(updated.count)); try file.synchronize()
    } catch {
        try? file.seek(toOffset: moovOffset); try? file.write(contentsOf: original)
        try? file.truncate(atOffset: fileSize)
        throw error
    }
}
