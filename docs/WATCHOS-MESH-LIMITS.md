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

The app declares the `bluetooth-central` background mode, subscribes to the
bitchat GATT characteristics, and enables Core Bluetooth state restoration.
While the UI is active, up to three connection attempts run concurrently and
the filtered scan remains armed until eight physical links are actually
connected. When the wrist is lowered, discovery stops because Apple counts
background scans against the same five-opportunity rolling budget used for
timely alerts. Established links and explicit Core Bluetooth reconnect requests
remain armed, but the watch deliberately parks all but two stable, distinct
alert relays because watchOS supports at most two background BLE connections
per app. The eight-link foreground mesh is restored as soon as the scene becomes
active. A Bluetooth alert wake performs a narrowly scoped recovery pass that:

- adopts system-connected peripherals and resumes known connections;
- temporarily reopens the normal mesh characteristic and requests sync only
  after Core Bluetooth confirms that subscription;
- uses a single compact wake signal for a message that cannot fit one alert
  update, rather than spending an opportunity on every fragment;
- persists conversation state.

Foreground runtime adds Android-style self-healing that cannot run while the
watch process is suspended:

- a watchdog is installed on every launch, even if the initial scene is
  already active;
- connect, service-discovery, characteristic-discovery, and notification
  subscription phases have explicit deadlines;
- stale attempts are cancelled and release their slots instead of waiting
  forever for Core Bluetooth callbacks;
- a central manager that still makes no progress is rebuilt at a bounded
  interval without discarding conversations, authenticated peers, or Noise
  state;
- scan candidates are briefly pooled and ranked by distinct peer identity,
  prior success, least-recent attempt, and RSSI;
- signed direct announcements bind physical peripherals to peer identities,
  allowing duplicate physical links to the same peer to be retired;
- each ready link announces and requests gossip sync, so reconnection fetches
  messages without requiring an app restart.

Routine presence/sync traffic and discovery are disabled wrist-down; only the
dedicated message-capable alert characteristic remains subscribed. Short Noise
messages omit redundant BLE transport padding on this already-encrypted lane so
one DM normally produces one GATT update. Peer-list
presence expiration is paused during this interval because absent announces
are not evidence of a disconnect, and valid Noise sessions are retained when
a foreground presence entry expires.

This is best-effort, not continuous execution. watchOS suspends application
code in the background and permits only five combined background-scan or timely
alert opportunities in a rolling 24-hour window; launching the app refreshes
the full budget. The implementation preserves those opportunities for messages,
but it cannot remove the operating-system limit.
Dispatch timers for announce heartbeats, retries, watchdogs, and fragment
recovery do not run while suspended; they catch up at the next granted
Bluetooth or foreground runtime.

Release validation must therefore include physical-device tests for:

1. foreground phone-to-watch discovery and two-way public/DM traffic;
2. an already connected watch receiving a DM while its UI is suspended;
3. reconnection after the advertising phone leaves and returns, including a
   deliberately stalled connect or subscription attempt;
4. delivery recovery when fragments or private-media acknowledgements are
   interrupted by suspension;
5. discovery and direct-link diversity with at least three simultaneous
   advertising peers;
6. behavior after the system's background Bluetooth budget is exhausted.

The product should describe the Apple Watch app as a nearby mesh participant,
not as an always-on relay equivalent to the Android Wear foreground service.
