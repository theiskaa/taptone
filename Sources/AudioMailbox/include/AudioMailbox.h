#ifndef TAPTONE_AUDIO_MAILBOX_H
#define TAPTONE_AUDIO_MAILBOX_H

#include <stdbool.h>
#include <stdint.h>

typedef struct TTAudioMailbox TTAudioMailbox;

enum { TTMailboxSlots = 32, TTMailboxMaxFrames = 8192 };

typedef struct {
    const float *stereo;
    uint64_t hostTimeNs;
    uint32_t frames;
    bool discontinuity;
} TTAudioPacket;

TTAudioMailbox *tt_mailbox_create(void);
void tt_mailbox_destroy(TTAudioMailbox *mailbox);

// Single producer. Stride is measured in floats and must be 1 (planar/mono) or 2 (interleaved).
bool tt_mailbox_write(TTAudioMailbox *mailbox, const float *left, const float *right,
                      uint32_t stride, uint32_t frames, uint64_t hostTimeNs);
void tt_mailbox_mark_gap(TTAudioMailbox *mailbox);

// Single consumer. A peeked packet remains valid until consume; destroy only after both endpoints stop.
bool tt_mailbox_peek(TTAudioMailbox *mailbox, TTAudioPacket *packet);
void tt_mailbox_consume(TTAudioMailbox *mailbox);

#endif
