# watchOS mesh runtime contract

The watchOS app implements the same Bluetooth-only bitchat wire behavior as
the Android Wear app where the operating system permits it: signed public
chat, relaying across established links, gossip sync, Noise direct messages,
receipts, private media, and voice notes.

It cannot provide the Android foreground-service availability contract.
watchOS does not support advertising services from `CBPeripheralManager`, so
the watch is a BLE central only. At least one nearby phone must advertise the
bitchat service before the watch can discover and join the mesh. Two watches
cannot discover each other directly.

The app declares the `bluetooth-central` background mode, uses a
service-filtered scan, subscribes to the bitchat GATT characteristic, and
enables Core Bluetooth state restoration. A Bluetooth alert wake performs an
event-driven maintenance pass that:

- resumes known peripheral connections and the filtered scan;
- announces the watch and requests gossip sync on ready links;
- requests missing fragments for stalled broadcast transfers;
- advances pending Noise handshakes and private-media sends;
- persists conversation state.

This is best-effort, not continuous execution. watchOS suspends application
code in the background and budgets background scan and timely-alert runtime.
Dispatch timers for announce heartbeats, retries, and fragment recovery do not
run while suspended; the maintenance pass catches them up at the next granted
Bluetooth or foreground runtime.

Release validation must therefore include physical-device tests for:

1. foreground phone-to-watch discovery and two-way public/DM traffic;
2. an already connected watch receiving a DM while its UI is suspended;
3. reconnection after the advertising phone leaves and returns;
4. delivery recovery when fragments or private-media acknowledgements are
   interrupted by suspension;
5. behavior after the system's background Bluetooth budget is exhausted.

The product should describe the Apple Watch app as a nearby mesh participant,
not as an always-on relay equivalent to the Android Wear foreground service.
