# Session Ping Gate

Run `just test-session-ping` to build the current module, publish it to a
disposable local SpacetimeDB instance on a dynamically allocated loopback port,
and run the real Godot client against it. The gate uses a private token
directory, database, container, and volumes, then removes those resources.

The probe is an authenticated call to the permission-independent
`diagnostic_echo` reducer. An `ok` or `okEmpty` reducer response is an
application acknowledgement for the client's own WebSocket session. The reducer
does not require an Operator role and does not mutate world state. This measures
the active application's request/acknowledgement path, not HTTP health RTT.
The test subscribes only to the sender-filtered `my_role` view. It first verifies
the joining identity's default Operator row (tag 1), then privately assigns Viewer
and reconnects with the same token to verify its persisted sender row (tag 2).
Both roles must receive twelve authenticated echo replies. Real HTTP reducer
checks additionally prove Operator management access, Admin-only speed denial,
and Viewer mutation denial without changing colony state.

RTT is measured from the timestamp immediately after the client WebSocket send
returns to the timestamp when `WebSocketPeer` first observes the response
packet. The matching reducer response is still required, but SDK packet
deserialization and GDScript result-queue delay are excluded. Godot exposes a
polling WebSocket API, so this is transport-observed RTT rather than a
kernel-level wire timestamp. The sampler sends at most one probe and enforces a
minimum one-second interval. Reducer errors, cancellations, and SDK send
failures are rejected outcomes rather than timeouts; timeout ratio counts only
settled successes and timeouts. Packet loss remains unavailable.
