import AudioMailbox
import Testing

@Suite struct AudioMailboxTests {
    @Test func packsPlanarAndInterleavedAudio() throws {
        let mailbox = try #require(tt_mailbox_create())
        defer { tt_mailbox_destroy(mailbox) }
        let stereo: [Float] = [0.25, -0.25, 0.5, -0.5]
        let accepted = stereo.withUnsafeBufferPointer { samples -> Bool in
            guard let head = samples.baseAddress else { return false }
            return tt_mailbox_write(mailbox, head, head + 1, 2, 2, 101)
        }
        #expect(accepted)
        let planar = tt_mailbox_write(mailbox, [0.25, 0.5], [-0.25, -0.5], 1, 2, 102)
        #expect(planar)
        for time: UInt64 in [101, 102] {
            var packet = TTAudioPacket()
            #expect(tt_mailbox_peek(mailbox, &packet))
            #expect(packet.hostTimeNs == time)
            #expect(packet.frames == 2)
            #expect(!packet.discontinuity)
            #expect(Array(UnsafeBufferPointer(start: packet.stereo, count: Int(packet.frames) * 2)) == stereo,
                    "Packet at \(time) ns")
            tt_mailbox_consume(mailbox)
        }
        var packet = TTAudioPacket()
        #expect(!tt_mailbox_peek(mailbox, &packet))
    }

    @Test func fullQueueDropsNewestAndMarksTheNextAcceptedPacket() throws {
        let mailbox = try #require(tt_mailbox_create())
        defer { tt_mailbox_destroy(mailbox) }
        for index in 0..<TTMailboxSlots {
            let accepted = tt_mailbox_write(mailbox, [1], [-1], 1, 1, UInt64(index))
            #expect(accepted)
        }
        let overflow = tt_mailbox_write(mailbox, [1], [-1], 1, 1, 100)
        #expect(!overflow)
        var packet = TTAudioPacket()
        #expect(tt_mailbox_peek(mailbox, &packet))
        #expect(packet.hostTimeNs == 0)
        tt_mailbox_consume(mailbox)
        let accepted = tt_mailbox_write(mailbox, [0], [0], 1, 1, 101)
        #expect(accepted)
        for index in 1...TTMailboxSlots {
            #expect(tt_mailbox_peek(mailbox, &packet))
            #expect(packet.hostTimeNs == (index == TTMailboxSlots ? 101 : UInt64(index)))
            #expect(packet.discontinuity == (index == TTMailboxSlots))
            tt_mailbox_consume(mailbox)
        }
    }

    @Test func rejectsOversizedFramesBeforeReading() throws {
        let mailbox = try #require(tt_mailbox_create())
        defer { tt_mailbox_destroy(mailbox) }
        let oversized = tt_mailbox_write(mailbox, [0], [0], 1, UInt32(TTMailboxMaxFrames) + 1, 1)
        let valid = tt_mailbox_write(mailbox, [0], [0], 1, 1, 2)
        #expect(!oversized)
        #expect(valid)
        var packet = TTAudioPacket()
        #expect(tt_mailbox_peek(mailbox, &packet))
        #expect(packet.discontinuity)
    }
}
