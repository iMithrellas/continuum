# Continuum SDK fork

Live `SpacetimeDBSubscription.unsubscribe()` and `SpacetimeDBClient.unsubscribe(query_id)` default to v2 `SendDroppedRows=1`, rather than protocol `Default=0`. The existing acknowledgment handler applies only server-reported dropped rows, preserving rows shared by other live queries; handles remain tracked until acknowledgment. Callers can explicitly pass `UnsubscribeMessage.UnsubscribeFlags.Default` to retain cached rows. Offline `discard_subscription(handle)` remains network-free and does not infer row ownership; session teardown must clear or destroy the old local database. Protocol reference: [v2 UnsubscribeFlags and UnsubscribeApplied](https://github.com/clockworklabs/SpacetimeDB/blob/master/crates/client-api-messages/src/websocket/v2.rs).

Backend-free regression: run `scripts/internal/test-sdk-subscription-cache` from the repository. It captures outgoing serialized requests and parses acknowledgment payloads with generated terrain rows through the real SDK/cache. Server dropped-row sets are fixtures, not a live-server integration test.

## U64 in Godot

Godot's `int` is signed 64-bit. BSATN U64 uses that same integer as a **full 64-bit wire pattern**: `0..2^63-1` have their usual values, `2^63` is represented by `-9223372036854775807 - 1`, and `2^64-1` by `-1`. Reading and writing preserve those bits exactly, including generated U64 fields and reducer arguments such as world seeds. The U64 writer accepts only integer Variants, never float/string/bool/byte-array conversions. Negative integers are not U64 sentinel errors at the codec layer; API-specific IDs, offsets, counts and sentinels must be validated in their own context. Signed comparisons/decimal formatting of a high-bit U64 follow Godot's signed representation, not unsigned numeric ordering. U8/U16/U32 retain nonnegative range guards; I64, UUID, identity and connection-ID encodings are unchanged.

This codec check does not prevent GDScript's earlier argument coercion. Generated
reducer methods declare integer parameters, so a caller passing `-1.5` may have it
converted to `-1` before the U64 writer runs. Validate user input before calling
generated methods; the SDK does not promise rejection of every implicit conversion.

Backend-free boundary and generated seed/reducer regression: `scripts/internal/test-sdk-u64-bitpatterns`.
