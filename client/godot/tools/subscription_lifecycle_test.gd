## Regression test for late acknowledgements after a local handle is discarded.
extends SceneTree


func _initialize() -> void:
	var client := ContinuumModuleClient.new()
	root.add_child(client)
	var subscribe_handle := SpacetimeDBSubscription.new()
	subscribe_handle.query_id = 17
	client.current_subscriptions[17] = subscribe_handle
	client.discard_subscription(subscribe_handle)
	var subscribe_ack := SubscribeAppliedMessage.new()
	subscribe_ack.query_id.id = 17
	client._handle_parsed_message(subscribe_ack)
	var unsubscribe_handle := SpacetimeDBSubscription.new()
	unsubscribe_handle.query_id = 18
	client.current_subscriptions[18] = unsubscribe_handle
	client.discard_subscription(unsubscribe_handle)
	var unsubscribe_ack := UnsubscribeAppliedMessage.new()
	unsubscribe_ack.query_id.id = 18
	client._handle_parsed_message(unsubscribe_ack)
	for pending: bool in [true, false]:
		var rejected := SpacetimeDBSubscription.create(
			client, 19, ["SELECT * FROM production_policy"]
		)
		client.add_child(rejected)
		if pending:
			client._pending_subscriptions[19] = rejected
		else:
			client.current_subscriptions[19] = rejected
		var details := [""]
		rejected.end.connect(
			func() -> void:
				details[0] = rejected.error_message
				assert(
					rejected.error == ERR_INVALID_DATA and rejected.ended and not rejected.active
				)
				assert(
					(
						not client._pending_subscriptions.has(19)
						and not client.current_subscriptions.has(19)
					)
				)
				client.discard_subscription(rejected)
		)
		var error := SubscriptionErrorMessage.new()
		error.query_id = QueryIdData.new(19)
		error.error_message = "no such table: production_policy"
		client._handle_parsed_message(error)
		assert(
			details[0] == error.error_message, "server error reaches end handlers before disposal"
		)
		client._handle_parsed_message(error)  # A late duplicate has no owner.
	var unscoped := SubscriptionErrorMessage.new()
	unscoped.error_message = "unscoped subscription error"
	client._handle_parsed_message(unscoped)  # Optional query IDs must not be dereferenced.
	print("SUBSCRIPTION_LIFECYCLE_PASS")
	quit(0)
