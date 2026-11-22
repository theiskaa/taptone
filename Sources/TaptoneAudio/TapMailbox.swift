import AudioMailbox
import CoreAudio

/// Immutable owner shared by exactly one HAL writer and one queue-confined reader.
final class TapMailbox: @unchecked Sendable {
    let storage: OpaquePointer

    init?() {
        guard let storage = tt_mailbox_create() else { return nil }
        self.storage = storage
    }

    deinit { tt_mailbox_destroy(storage) }

    /// Called on the HAL realtime thread. Do not allocate, log, lock, or enqueue work here.
    func write(_ input: UnsafePointer<AudioBufferList>, hostTimeNs: UInt64) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let left = first.mData?.assumingMemoryBound(to: Float.self) else {
            tt_mailbox_mark_gap(storage)
            return
        }
        switch (buffers.count, first.mNumberChannels) {
        case (1, 2) where first.mDataByteSize.isMultiple(of: 8) && first.mDataByteSize >= 8:
            _ = tt_mailbox_write(storage, left, left + 1, 2, first.mDataByteSize / 8, hostTimeNs)
        case (1, 1) where first.mDataByteSize.isMultiple(of: 4):
            _ = tt_mailbox_write(storage, left, left, 1, first.mDataByteSize / 4, hostTimeNs)
        case (2, 1) where first.mDataByteSize.isMultiple(of: 4):
            let second = buffers[1]
            guard second.mNumberChannels == 1, second.mDataByteSize == first.mDataByteSize,
                  let right = second.mData?.assumingMemoryBound(to: Float.self) else {
                tt_mailbox_mark_gap(storage)
                return
            }
            _ = tt_mailbox_write(storage, left, right, 1, first.mDataByteSize / 4, hostTimeNs)
        default:
            tt_mailbox_mark_gap(storage)
        }
    }
}
