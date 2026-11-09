import AVFoundation

/// Voice messages as the website sends them: Opus audio in an Ogg file, mono, 48 kHz, with a
/// waveform of 64 levels from 0 to 100.
enum OggOpus {
    struct Encoded {
        let data: Data
        /// Seconds.
        let duration: Double
        /// 64 levels from 0 to 100, as the website sends them with a voice clip.
        let amplitudes: [Int]
    }

    enum Failure: LocalizedError {
        case unsupported
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported: "This phone couldn't encode the voice message."
            case .empty: "The recording is empty."
            }
        }
    }

    static let sampleRate = 48_000.0
    /// What players skip at the start for the encoder's lookahead: libopus's usual 6.5 ms.
    static let preSkip: UInt16 = 312

    /// Encodes a recording (anything AVAudioFile reads, at 48 kHz mono) as Ogg Opus.
    static func encode(pcm url: URL, bitRate: Int = 32_000) throws -> Encoded {
        let file = try AVAudioFile(forReading: url)
        let input = file.processingFormat
        guard input.sampleRate == sampleRate, input.channelCount == 1 else { throw Failure.unsupported }
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frameCount) else {
            throw Failure.empty
        }
        try file.read(into: pcm)

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        guard let opus = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: opus)
        else { throw Failure.unsupported }
        if converter.applicableEncodeBitRates?.contains(NSNumber(value: bitRate)) == true {
            converter.bitRate = bitRate
        }

        var packets: [Data] = []
        var given = false
        let packetSize = max(converter.maximumOutputPacketSize, 1276)
        while true {
            let output = AVAudioCompressedBuffer(format: opus, packetCapacity: 64, maximumPacketSize: packetSize)
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                if given {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if let failure { throw failure }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let packet = descriptions[index]
                    packets.append(Data(bytes: output.data.advanced(by: Int(packet.mStartOffset)), count: Int(packet.mDataByteSize)))
                }
            }
            if status == .endOfStream || status == .error || output.packetCount == 0 { break }
        }
        guard !packets.isEmpty else { throw Failure.empty }
        return Encoded(data: mux(packets), duration: Double(pcm.frameLength) / sampleRate, amplitudes: waveform(of: pcm))
    }

    /// Each slice's loudness between -60 and -10 dB, the range the website's recorder measures,
    /// as 0 to 100.
    static func waveform(of pcm: AVAudioPCMBuffer, points: Int = 64) -> [Int] {
        guard let samples = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return [] }
        let count = Int(pcm.frameLength)
        return (0..<points).map { index in
            let start = index * count / points
            let end = min(max(start + 1, (index + 1) * count / points), count)
            var sum: Float = 0
            for sample in start..<end { sum += samples[sample] * samples[sample] }
            let rms = sqrt(sum / Float(max(end - start, 1)))
            let decibels = 20 * log10(max(Double(rms), 1e-9))
            return Int(min(max((decibels + 60) / 50, 0), 1) * 100)
        }
    }

    // MARK: Ogg (RFC 3533, 7845)

    /// Opus packets in Ogg pages: the identification and comment headers, then about a second of
    /// audio per page.
    static func mux(_ packets: [Data]) -> Data {
        var file = Data()
        let serial = UInt32.random(in: 1...UInt32.max)
        var sequence: UInt32 = 0

        func page(_ contents: [Data], granule: Int64, flags: UInt8) {
            var lacing: [UInt8] = []
            var body = Data()
            for packet in contents {
                var size = packet.count
                while size >= 255 {
                    lacing.append(255)
                    size -= 255
                }
                lacing.append(UInt8(size))
                body.append(packet)
            }
            var page = Data("OggS".utf8)
            page.append(0)
            page.append(flags)
            page.append(littleEndian: UInt64(bitPattern: granule))
            page.append(littleEndian: serial)
            page.append(littleEndian: sequence)
            page.append(littleEndian: UInt32(0))
            page.append(UInt8(lacing.count))
            page.append(contentsOf: lacing)
            page.append(body)
            let crc = checksum(page)
            page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
            file.append(page)
            sequence += 1
        }

        var head = Data("OpusHead".utf8)
        head.append(1)
        head.append(1)
        head.append(littleEndian: preSkip)
        head.append(littleEndian: UInt32(sampleRate))
        head.append(littleEndian: UInt16(0))
        head.append(0)
        page([head], granule: 0, flags: 0x02)

        var tags = Data("OpusTags".utf8)
        let vendor = Data("Unreeled".utf8)
        tags.append(littleEndian: UInt32(vendor.count))
        tags.append(vendor)
        tags.append(littleEndian: UInt32(0))
        page([tags], granule: 0, flags: 0)

        var granule: Int64 = 0
        var waiting: [Data] = []
        var segments = 0
        for packet in packets {
            let needed = packet.count / 255 + 1
            if !waiting.isEmpty, segments + needed > 255 || waiting.count >= 50 {
                page(waiting, granule: granule, flags: 0)
                waiting = []
                segments = 0
            }
            waiting.append(packet)
            segments += needed
            granule += Int64(samples(in: packet))
        }
        page(waiting, granule: granule, flags: 0x04)
        return file
    }

    /// 48 kHz samples in an Opus packet, from its table-of-contents byte (RFC 6716, 3.1).
    static func samples(in packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Int
        switch config {
        case 0...11: frame = [480, 960, 1920, 2880][config % 4]
        case 12...15: frame = [480, 960][config % 2]
        default: frame = [120, 240, 480, 960][config % 4]
        }
        switch toc & 0x03 {
        case 0: return frame
        case 1, 2: return frame * 2
        default: return frame * (packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 1)
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)] }
        return crc
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
