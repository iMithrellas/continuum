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
	print("SUBSCRIPTION_LIFECYCLE_PASS")
	quit(0)
