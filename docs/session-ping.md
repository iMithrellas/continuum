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
The test subscribes only to the sender-filtered `my_role` view and verifies that
the connected client is a Viewer with no operator membership.

RTT is measured from the monotonic client send timestamp to the matching
reducer response. The sampler sends at most one probe and enforces a minimum
one-second interval. Reducer errors, cancellations, and SDK send failures are
rejected outcomes rather than timeouts; timeout ratio counts only settled
successes and timeouts. Packet loss remains unavailable.
