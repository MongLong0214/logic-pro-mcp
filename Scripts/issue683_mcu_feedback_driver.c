// CoreMIDI half of Scripts/test_mcu_feedback_jsonrpc_liveness.py.
//
// It opens an output port and sends the MCU frames observed from Logic Pro
// straight to the server's LogicProMCP-MCU-Internal destination, the way Logic
// delivers to a bound control surface.  This keeps the Python driver free of
// CoreMIDI bindings while exercising the same endpoint direction as Logic.

#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    kCoreMIDIUnavailable = 77,
    kDestinationNotFound = 78,
    kConnectionFailed = 79,
    kSendFailed = 80,
};

static MIDIEndpointRef findDestination(const char *targetName) {
    CFStringRef target = CFStringCreateWithCString(NULL, targetName, kCFStringEncodingUTF8);
    if (target == NULL) return 0;

    MIDIEndpointRef found = 0;
    for (ItemCount index = 0; index < MIDIGetNumberOfDestinations(); index++) {
        MIDIEndpointRef endpoint = MIDIGetDestination(index);
        CFStringRef name = NULL;
        if (MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) != noErr || name == NULL) {
            continue;
        }
        Boolean matches = CFEqual(name, target);
        CFRelease(name);
        if (matches) {
            found = endpoint;
            break;
        }
    }
    CFRelease(target);
    return found;
}

// Send straight to the server's destination through an output port, the way a
// real MIDI application (Logic included) delivers to a bound surface.
//
// An earlier version created a virtual source and a MIDIThruConnection instead.
// That routed through `MIDISource::AddThruConnection`, and MIDIServer segfaulted
// there twice on a developer host — EXC_BAD_ACCESS inside
// `MIDIDestination::SendPacketsNow`, with crash reports to show for it. A dead
// MIDIServer takes every CoreMIDI client in every process down with it, so a
// harness must not reach that path.
static OSStatus sendPacket(MIDIPortRef port, MIDIEndpointRef destination, const Byte *bytes, UInt16 count) {
    Byte storage[1024];
    if (count > sizeof(storage) - sizeof(MIDIPacketList)) return -50;  // paramErr
    MIDIPacketList *list = (MIDIPacketList *)storage;
    MIDIPacket *packet = MIDIPacketListInit(list);
    if (MIDIPacketListAdd(list, sizeof(storage), packet, 0, count, bytes) == NULL) return -50;
    return MIDISend(port, destination, list);
}

int main(int argc, const char *argv[]) {
    const char *targetName = argc == 2 ? argv[1] : "LogicProMCP-MCU-Internal";

    MIDIClientRef client = 0;
    OSStatus status = MIDIClientCreate(CFSTR("LogicProMCP-Issue683-Driver"), NULL, NULL, &client);
    if (status != noErr) {
        fprintf(stderr, "CoreMIDI unavailable: MIDIClientCreate status %d\n", (int)status);
        return kCoreMIDIUnavailable;
    }

    MIDIEndpointRef destination = findDestination(targetName);
    if (destination == 0) {
        fprintf(stderr, "Server destination '%s' was not found\n", targetName);
        MIDIClientDispose(client);
        return kDestinationNotFound;
    }

    MIDIPortRef outputPort = 0;
    status = MIDIOutputPortCreate(client, CFSTR("LogicProMCP-Issue683-Out"), &outputPort);
    if (status != noErr) {
        fprintf(stderr, "CoreMIDI unavailable: MIDIOutputPortCreate status %d\n", (int)status);
        MIDIClientDispose(client);
        return kCoreMIDIUnavailable;
    }

    // Device queries include ids that this server does not own, followed by a
    // truncated SysEx and the normal meter/LCD/fader/V-Pot/button/timecode
    // feedback shapes from the reported trace.
    static const Byte deviceQueries[][7] = {
        {0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7},
        {0xF0, 0x00, 0x00, 0x66, 0x10, 0x00, 0xF7},
        {0xF0, 0x00, 0x00, 0x66, 0x11, 0x00, 0xF7},
        {0xF0, 0x00, 0x00, 0x66, 0x15, 0x00, 0xF7},
        {0xF0, 0x00, 0x00, 0x66, 0x17, 0x00, 0xF7},
    };
    static const Byte truncatedSysEx[] = {0xF0, 0x00, 0x00, 0x66, 0x14, 0x00};
    static const Byte channelPressure[] = {0xD0, 0x40};
    static const Byte lcdText[] = {0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 0x00, 'T', 'R', 'A', 'C', 'K', ' ', '1', 0xF7};
    static const Byte fader[] = {0xE0, 0x00, 0x40};
    static const Byte vpot[] = {0xB0, 0x30, 0x46};
    static const Byte button[] = {0x90, 0x12, 0x7F};
    static const Byte timecode[] = {0xB0, 0x40, 0x01};
    static const Byte *const packets[] = {
        deviceQueries[0], deviceQueries[1], deviceQueries[2], deviceQueries[3], deviceQueries[4],
        truncatedSysEx, channelPressure, lcdText, fader, vpot, button, timecode,
    };
    static const UInt16 lengths[] = {7, 7, 7, 7, 7, 6, 2, 15, 3, 3, 3, 3};
    const size_t packetCount = sizeof(packets) / sizeof(packets[0]);

    // Confirm a packet has entered the route before the Python driver sends
    // tools/list. The remaining packets stay in flight concurrently with that
    // protocol-local request.
    status = sendPacket(outputPort, destination, packets[0], lengths[0]);
    if (status != noErr) {
        fprintf(stderr, "MIDISend failed: status %d\n", (int)status);
        MIDIClientDispose(client);
        return kSendFailed;
    }
    fputs("SENDING\n", stdout);
    fflush(stdout);

    // Same cardinality as the captured 15-second exchange, but paced at 10ms
    // so this remains a liveness check rather than a throughput benchmark.
    for (size_t index = 1; index < 142; index++) {
        status = sendPacket(outputPort, destination, packets[index % packetCount], lengths[index % packetCount]);
        if (status != noErr) {
            fprintf(stderr, "MIDISend failed: status %d\n", (int)status);
            MIDIClientDispose(client);
            return kSendFailed;
        }
        usleep(10 * 1000);
    }

    MIDIClientDispose(client);
    return 0;
}
