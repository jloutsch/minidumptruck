import Foundation

/// Minimal Multi-Stream File (MSF) 7.0 reader — the container format
/// PDB 7.0 files use. Microsoft's symbol server has shipped PDB 7.0
/// exclusively since the early 2000s, so we don't bother with the older
/// "Big MSF" PDB 2.0 format.
///
/// Format reference: https://llvm.org/docs/PDB/MsfFile.html
///
/// Layout:
///
///     SuperBlock     (block 0)
///     FPM1 / FPM2    (blocks 1 and 2, alternating free-page maps)
///     Stream data    (every other block, interleaved with FPM)
///
/// The SuperBlock points at a "block map" block which itself contains
/// a list of block indices comprising the *Stream Directory*. The
/// directory enumerates every stream's size and block list. Once you
/// have the directory, reading any stream means "concatenate the bytes
/// at each block index, then truncate to the recorded size."
public struct MSFFile: Sendable {
    /// 32-byte MSF 7.0 magic. NUL-terminated in the file; we compare
    /// the prefix to allow for any trailing padding.
    static let magic: [UInt8] = [
        0x4D, 0x69, 0x63, 0x72, 0x6F, 0x73, 0x6F, 0x66,  // "Microsof"
        0x74, 0x20, 0x43, 0x2F, 0x43, 0x2B, 0x2B, 0x20,  // "t C/C++ "
        0x4D, 0x53, 0x46, 0x20, 0x37, 0x2E, 0x30, 0x30,  // "MSF 7.00"
        0x0D, 0x0A, 0x1A, 0x44, 0x53, 0x00, 0x00, 0x00   // "\r\n\x1ADS\0\0\0"
    ]

    public enum ParseError: Error, Sendable, Equatable {
        case fileTooSmall
        case badMagic
        case invalidBlockSize(UInt32)
        case blockIndexOutOfRange(UInt32)
        case streamSizeOutOfRange(UInt32)
        case directoryReadFailure
        case streamExceedsFileSize
    }

    /// Cap on the size of any single stream we'll materialize. PDBs
    /// for OS DLLs are well under 100 MB; an attacker-controlled or
    /// MitM-served PDB could declare a stream size up to UInt32.max
    /// (~4 GB), and a Memory64-style DoS via 8 concurrent fetches
    /// could attempt 32 GB of allocations. 256 MB is generous for
    /// real-world PDBs and bounded for safety.
    public static let maxStreamSize: Int = 256 * 1024 * 1024

    /// The parsed SuperBlock fields we use.
    public struct SuperBlock: Sendable {
        public let blockSize: UInt32
        public let numBlocks: UInt32
        public let numDirectoryBytes: UInt32
        public let blockMapAddr: UInt32  // block index of the block-map block
    }

    /// Per-stream metadata extracted from the Stream Directory.
    public struct StreamInfo: Sendable {
        public let size: UInt32          // bytes
        public let blockIndices: [UInt32]
    }

    private let data: Data
    public let superBlock: SuperBlock
    public let streams: [StreamInfo]     // indexed by stream number

    /// Parse an MSF file. Throws `ParseError` on any structural problem.
    public init(data: Data) throws {
        self.data = data
        guard data.count >= 56 else { throw ParseError.fileTooSmall }

        // Magic compare — first 32 bytes.
        for i in 0..<32 where data[i] != MSFFile.magic[i] {
            throw ParseError.badMagic
        }

        // SuperBlock fields after the magic
        guard let blockSize = data.readUInt32(at: 32),
              data.readUInt32(at: 36) != nil,         // FreeBlockMapBlock (1 or 2) — unused
              let numBlocks = data.readUInt32(at: 40),
              let numDirectoryBytes = data.readUInt32(at: 44),
              data.readUInt32(at: 48) != nil,         // reserved/Unknown
              let blockMapAddr = data.readUInt32(at: 52)
        else {
            throw ParseError.directoryReadFailure
        }

        // BlockSize must be a power of two from 512..32768; common values
        // are 4096, 8192, 16384, 32768.
        let validSizes: Set<UInt32> = [512, 1024, 2048, 4096, 8192, 16384, 32768]
        guard validSizes.contains(blockSize) else {
            throw ParseError.invalidBlockSize(blockSize)
        }

        // numBlocks * blockSize must fit inside the actual file. A
        // malformed PDB that claims to be larger than its bytes can't
        // possibly be valid; we reject early instead of failing
        // later on individual block reads.
        let (claimedFileSize, fileSizeOverflow) = numBlocks.multipliedReportingOverflow(by: blockSize)
        guard !fileSizeOverflow, Int(claimedFileSize) <= data.count else {
            throw ParseError.streamExceedsFileSize
        }

        // Directory size and per-stream sizes are also attacker-
        // influenced (CodeView -> PDBIdentity -> server URL -> bytes).
        // Cap each at `maxStreamSize` to bound memory.
        guard Int(numDirectoryBytes) <= MSFFile.maxStreamSize else {
            throw ParseError.streamSizeOutOfRange(numDirectoryBytes)
        }

        self.superBlock = SuperBlock(
            blockSize: blockSize,
            numBlocks: numBlocks,
            numDirectoryBytes: numDirectoryBytes,
            blockMapAddr: blockMapAddr
        )

        // Pull the directory bytes out of the directory's block list.
        // Step 1: read the block-map block — it contains the block
        // indices that hold the actual directory.
        let directoryBlockCount = Int((numDirectoryBytes + blockSize - 1) / blockSize)
        let mapBlockOffset = Int(blockMapAddr) * Int(blockSize)
        guard mapBlockOffset >= 0,
              mapBlockOffset + directoryBlockCount * 4 <= data.count
        else { throw ParseError.directoryReadFailure }

        var directoryBlockIndices: [UInt32] = []
        directoryBlockIndices.reserveCapacity(directoryBlockCount)
        for i in 0..<directoryBlockCount {
            guard let idx = data.readUInt32(at: mapBlockOffset + i * 4) else {
                throw ParseError.directoryReadFailure
            }
            directoryBlockIndices.append(idx)
        }

        // Step 2: concatenate directory bytes from those blocks.
        let directoryData = try MSFFile.concatenateBlocks(
            directoryBlockIndices,
            blockSize: blockSize,
            from: data,
            limit: Int(numDirectoryBytes)
        )

        // Step 3: parse the directory.
        // Format: NumStreams (u32), StreamSizes[u32; NumStreams],
        //         then for each stream a block list of ceil(size/blockSize) u32s.
        guard let numStreams = directoryData.readUInt32(at: 0) else {
            throw ParseError.directoryReadFailure
        }
        var streams: [StreamInfo] = []
        streams.reserveCapacity(Int(numStreams))

        // Read the stream sizes.
        var sizes: [UInt32] = []
        sizes.reserveCapacity(Int(numStreams))
        for i in 0..<Int(numStreams) {
            guard let size = directoryData.readUInt32(at: 4 + i * 4) else {
                throw ParseError.directoryReadFailure
            }
            sizes.append(size)
        }

        // After the sizes table, block indices follow per stream.
        var cursor = 4 + Int(numStreams) * 4
        for size in sizes {
            // Special marker: 0xFFFFFFFF means "stream does not exist".
            // We treat those as zero-byte streams with no blocks.
            if size == 0xFFFF_FFFF {
                streams.append(StreamInfo(size: 0, blockIndices: []))
                continue
            }
            // Reject streams larger than our memory cap before computing
            // the block-count loop, otherwise an attacker can declare
            // size=UInt32.max and force the parser to walk a huge list.
            guard Int(size) <= MSFFile.maxStreamSize else {
                throw ParseError.streamSizeOutOfRange(size)
            }
            let blockCount = Int((size + blockSize - 1) / blockSize)
            var blocks: [UInt32] = []
            blocks.reserveCapacity(blockCount)
            for _ in 0..<blockCount {
                guard let idx = directoryData.readUInt32(at: cursor) else {
                    throw ParseError.directoryReadFailure
                }
                blocks.append(idx)
                cursor += 4
            }
            streams.append(StreamInfo(size: size, blockIndices: blocks))
        }

        self.streams = streams
    }

    /// Read a single stream's bytes by index. Returns nil if the index
    /// is out of range or a referenced block falls outside the file.
    public func readStream(_ index: Int) -> Data? {
        guard index >= 0, index < streams.count else { return nil }
        let stream = streams[index]
        return try? MSFFile.concatenateBlocks(
            stream.blockIndices,
            blockSize: superBlock.blockSize,
            from: data,
            limit: Int(stream.size)
        )
    }

    // Concatenate `BlockSize` bytes per block index, truncated to `limit`.
    private static func concatenateBlocks(
        _ blockIndices: [UInt32],
        blockSize: UInt32,
        from data: Data,
        limit: Int
    ) throws -> Data {
        var out = Data(capacity: limit)
        let blockSizeInt = Int(blockSize)
        for blockIdx in blockIndices {
            let offset = Int(blockIdx) * blockSizeInt
            guard offset >= 0, offset + blockSizeInt <= data.count else {
                throw ParseError.blockIndexOutOfRange(blockIdx)
            }
            // Stop early when we've reached the recorded byte count —
            // the last block is typically partially used.
            let remaining = limit - out.count
            guard remaining > 0 else { break }
            let take = min(blockSizeInt, remaining)
            out.append(data.subdata(in: offset..<(offset + take)))
        }
        return out
    }
}
