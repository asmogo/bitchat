# watchOS mesh runtime contract

The watchOS app implements the same Bluetooth-only bitchat wire behavior as
the Android Wear app where the operating system permits it: signed public
chat, relaying across established links, gossip sync, Noise direct messages,
receipts, private media, and voice notes. Peers that never complete the
Noise-bound capability exchange (current Android) are sent private media via
the same signed, directed, relay-visible fileTransfer fallback iOS uses, and
the watch accepts such directed transfers as private media. A peer that did
prove encrypted private media before stays pinned to it, so a missing or
expired proof can never force a clear-media downgrade.

It cannot provide the Android foreground-service availability contract.
watchOS does not support advertising services from `CBPeripheralManager`, so
the watch is a BLE central only. At least one nearby phone must advertise the
bitchat service before the watch can discover and join the mesh. Two watches
cannot discover each other directly.

Noise sessions follow the iOS regeneration policy: an established transport
ignores non-initial handshake bytes instead of tearing down its keys, and a
fresh initiation retires the current transport to receive-only quarantine
until the replacement handshake completes, so messages encrypted to the old
generation still decrypt in flight. Crossed initiations resolve
deterministically — the lexicographically lower peer ID keeps the initiator
role, the higher one yields.

The app declares the `bluetooth-central` background mode, subscribes to the
bitchat GATT characteristics, and enables Core Bluetooth state restoration.
Its central manager is instantiated from the SwiftUI `App` initializer on
every process launch, including a Bluetooth restoration launch which never
presents `ContentView`; view appearance is only an idempotent fallback.
The watchOS 10 deployment target still includes Apple Watch Series 4 and 5,
but Apple supports background timely-alert listening and background peripheral
discovery only on Series 6 or later. Older supported watches can participate
while the app has foreground runtime; wrist-down DM wakes are not available on
that hardware.
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
- temporarily reopens the normal mesh characteristic so spooled directed
  packets flush and live traffic flows for the drain window;
- drives that drain from whichever path delivered the wake — the SwiftUI
  Bluetooth-alert task or the Core Bluetooth delegate callback directly —
  so delivery does not depend on the task being granted;
- keeps in-flight fragment assemblies inside the granted Bluetooth-alert
  task for up to a four-second hard cap; it does not schedule a drain timer
  after returning from the task, when watchOS may suspend it immediately;
- never issues gossip-sync or fragment-resync requests wrist-down: their
  response bursts spend the same five-opportunity budget as message wakes,
  so sync stays a foreground activity and catch-up runs on the next granted
  foreground runtime;
- uses a single compact wake signal for a message that cannot fit one alert
  update, rather than spending an opportunity on every fragment;
- admits a directed Noise handshake to the alert lane after either process
  relaunches, then drains the encrypted message over the reopened mesh lane;
- persists conversation state.

Foreground runtime adds Android-style self-healing that cannot run while the
watch process is suspended:

- a watchdog is installed on every launch, even if the initial scene is
  already active;
- connect, service-discovery, characteristic-discovery, and notification
  subscription phases have explicit deadlines;
- stale attempts are cancelled and release their slots instead of waiting
  forever for Core Bluetooth callbacks — including immediately on every
  foreground return, so system-owned background connect requests cannot
  starve the resume path;
- peripherals whose connection attempts keep failing cool down with an
  exponential backoff (up to ten minutes), and fresh discoveries weaker than
  -90 dBm are never given a slot, so unreachable advertisers cannot occupy
  all concurrent attempts indefinitely;
- a central manager that still makes no progress is rebuilt at a bounded
  interval without discarding conversations, authenticated peers, or Noise
  state;
- scan candidates are briefly pooled and ranked by distinct peer identity,
  prior success, least-recent attempt, and RSSI;
- signed direct announcements bind physical peripherals to peer identities,
  allowing duplicate physical links to the same peer to be retired;
- each ready link announces and requests gossip sync, so reconnection fetches
  messages without requiring an app restart.

The Always-On state (scene `.inactive`) is treated as foreground for the
transport but not as interactive for notification/read-receipt policy.
Lowering the wrist to a dimmed screen must not tear down links, but a message
received while the conversation is no longer actually visible must still post
a notification. The inactive transition does not trigger a new gossip or fragment
resync burst. Lifecycle changes are observed at the app scene, including launches
which never present the conversation view. Recreating an inactive conversation
does not clear its notifications or send read receipts; those wait until it is
interactive. Frontmost notifications are also retained in Notification Center.
Only a real scene-background transition reduces the transport,
and even then links with in-flight fragment assemblies are kept until the
transfer completes.

Core Bluetooth subscription changes are asynchronous. The watch records one
in-flight mesh-lane transition per link and, from every callback, converges to
the latest lifecycle target. A late wrist-down unsubscribe can therefore no
longer switch off the mesh lane after the app has already returned. Repeated
transition failures rebuild the link instead of leaving a foreground connection
permanently alert-only; a transition that produces no delegate callback is
also timed out and rebuilt. If the phone invalidates/rebuilds its GATT service,
the watch discards every stale characteristic reference and immediately
rediscovers/subscribes on the existing connection.
The full-mesh lane stays subscribed until Core Bluetooth confirms that the
dedicated alert subscription is active. Merely discovering an alert characteristic
does not establish a wake path. Once the alert subscription succeeds, the mesh
lane converges to the current foreground/background state.

Notification authorization is checked at launch and whenever the UI becomes
interactive. Mesh diagnostics reports `enabled`, `denied`, or `not requested`
so an OS-level notification denial is distinguishable from a BLE delivery
failure.

On iOS state restoration, the phone preserves Core Bluetooth's restored GATT
service and reconstructs the mesh/alert subscriber sets from each restored
characteristic. It does not call `removeAllServices`, which would destroy those
subscriptions. New alert characteristics use acknowledged GATT indications.
A bounded, expiring central→peer routing hint is restored only to route the
fresh Noise handshake; Noise authentication itself is never persisted or
restored, and authenticated traffic remains blocked until that handshake
completes.

Routine presence/sync traffic and discovery are disabled wrist-down; only the
dedicated direct-message alert characteristic remains subscribed. Public chat,
receipts, relationship/capability state, private-media control traffic, and live
PTT never enter this lane; they wait for foreground or full-link runtime so the
five daily opportunities remain available for user-visible encrypted DMs.
Links to legacy peers without that characteristic keep their full-mesh
subscription, because it is their only remaining wake path. Short Noise DMs
and opaque handshake payloads omit redundant BLE transport padding on this
lane so one wake normally produces one GATT update. Peer-list
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

The app also requests a background refresh no earlier than fifteen minutes
later and renews the request when delivered. Frequent wrist/scene transitions
do not keep pushing the pending request back. When watchOS grants that runtime,
the app resumes known connections and runs the same bounded message drain,
then restores alert-only subscriptions. It does not scan or initiate gossip
bursts during this recovery pass. This is a fallback opportunity, not a
fifteen-minute polling guarantee: watchOS controls eligibility, timing, and
throttling, and allocates substantially more refresh time to frontmost apps or
apps with an active complication. This app currently has no complication.
An explicit Stop in diagnostics persists across background relaunches; a refresh
does not silently restart the mesh.

There is no WatchConnectivity packet transport in this implementation. A paired
iPhone can act as an ordinary BLE relay, and iOS notifications can be forwarded
by the system, but that does not synchronize the Watch's separate encrypted
inbox. A future companion transport would need to carry authenticated/encrypted
packets and preserve deduplication, bounded queues, and the standalone identity;
it must not advertise continuous or immediate delivery from WatchConnectivity,
whose background transfers are also system-scheduled.

Release validation must therefore include physical-device tests for:

1. foreground phone-to-watch discovery and two-way public/DM traffic;
2. an already connected Series 6-or-later watch receiving a DM while its UI is
   suspended;
3. the wrist-up/down and `.active`/`.inactive` transition while a mesh
   subscribe or unsubscribe callback is deliberately delayed;
4. system termination/restoration of either process while the watch is
   alert-only, verifying subscriber recovery and fresh Noise authentication;
   separately verify that a user force-quit requires a manual relaunch, as
   required by the OS;
5. reconnection after the advertising phone leaves and returns, including a
   deliberately stalled connect or subscription attempt;
6. delivery recovery when fragments or private-media acknowledgements are
   interrupted by suspension;
7. discovery and direct-link diversity with at least three simultaneous
   advertising peers;
8. behavior after the system's background Bluetooth budget is exhausted;
9. foreground mesh behavior on a Series 4 or 5, without assuming background
   timely-alert or scan delivery.

The product should describe the Apple Watch app as a nearby mesh participant,
not as an always-on relay equivalent to the Android Wear foreground service.
