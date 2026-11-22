#include "AudioMailbox.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "mailbox indices must be lock-free");
_Static_assert((TTMailboxSlots & (TTMailboxSlots - 1)) == 0, "slot count must be a power of two");

typedef struct {
    float stereo[TTMailboxMaxFrames * 2];
    uint64_t hostTimeNs;
    uint32_t frames;
    bool discontinuity;
} Slot;

struct TTAudioMailbox {
    atomic_uint writeIndex;
    atomic_uint readIndex;
    bool gapPending; // producer only
    Slot slots[TTMailboxSlots];
};

TTAudioMailbox *tt_mailbox_create(void) {
    TTAudioMailbox *mailbox = malloc(sizeof(*mailbox));
    if (mailbox == NULL) return NULL;
    // Touch the backing pages before the audio callback ever writes to them.
    memset(mailbox, 0, sizeof(*mailbox));
    atomic_init(&mailbox->writeIndex, 0);
    atomic_init(&mailbox->readIndex, 0);
    return mailbox;
}

void tt_mailbox_destroy(TTAudioMailbox *mailbox) { free(mailbox); }

void tt_mailbox_mark_gap(TTAudioMailbox *mailbox) { mailbox->gapPending = true; }

bool tt_mailbox_write(TTAudioMailbox *mailbox, const float *left, const float *right,
                      uint32_t stride, uint32_t frames, uint64_t hostTimeNs) {
    unsigned write = atomic_load_explicit(&mailbox->writeIndex, memory_order_relaxed);
    unsigned read = atomic_load_explicit(&mailbox->readIndex, memory_order_acquire);
    if (write - read >= TTMailboxSlots || left == NULL || right == NULL ||
        frames == 0 || frames > TTMailboxMaxFrames || (stride != 1 && stride != 2)) {
        mailbox->gapPending = true;
        return false;
    }
    Slot *slot = &mailbox->slots[write & (TTMailboxSlots - 1)];
    if (stride == 2 && right == left + 1) {
        memcpy(slot->stereo, left, (size_t)frames * 2 * sizeof(float));
    } else {
        for (uint32_t i = 0; i < frames; ++i) {
            slot->stereo[i * 2] = left[i * stride];
            slot->stereo[i * 2 + 1] = right[i * stride];
        }
    }
    slot->frames = frames;
    slot->hostTimeNs = hostTimeNs;
    slot->discontinuity = mailbox->gapPending;
    mailbox->gapPending = false;
    atomic_store_explicit(&mailbox->writeIndex, write + 1, memory_order_release);
    return true;
}

bool tt_mailbox_peek(TTAudioMailbox *mailbox, TTAudioPacket *packet) {
    unsigned read = atomic_load_explicit(&mailbox->readIndex, memory_order_relaxed);
    unsigned write = atomic_load_explicit(&mailbox->writeIndex, memory_order_acquire);
    if (read == write) return false;
    const Slot *slot = &mailbox->slots[read & (TTMailboxSlots - 1)];
    *packet = (TTAudioPacket){slot->stereo, slot->hostTimeNs, slot->frames, slot->discontinuity};
    return true;
}

void tt_mailbox_consume(TTAudioMailbox *mailbox) {
    unsigned read = atomic_load_explicit(&mailbox->readIndex, memory_order_relaxed);
    atomic_store_explicit(&mailbox->readIndex, read + 1, memory_order_release);
}
