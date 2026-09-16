use crate::auth::{authorize, identity_hex, RequiredRole};
use crate::events::log_event;
use crate::schema::*;
use crate::sim::WorkType;
use spacetimedb::{reducer, ReducerContext, Table};

/// Create or update an intent using only the server's tile and validated tuple ID.
#[reducer]
pub fn set_work_order(
    ctx: &ReducerContext,
    tile_id: u32,
    work: WorkType,
    priority: u8,
    enabled: bool,
) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let tile = ctx
        .db
        .tile()
        .id()
        .find(tile_id)
        .ok_or_else(|| format!("no such tile: {tile_id}"))?;
    let order = crate::sim::WorkOrder::new(
        &crate::sim::Tile {
            id: tile.id,
            x: tile.x,
            y: tile.y,
            kind: tile.kind,
            enabled: tile.enabled,
        },
        work,
        priority,
        enabled,
    )?;
    let existing = ctx.db.work_order().id().find(order.id);
    if existing.as_ref().is_some_and(|existing| {
        existing.tile_id == order.tile_id
            && existing.work == order.work
            && existing.priority == order.priority
            && existing.enabled == order.enabled
    }) {
        return Ok(());
    }
    let row = WorkOrder {
        id: order.id,
        tile_id: order.tile_id,
        work: order.work,
        priority: order.priority,
        enabled: order.enabled,
    };
    if existing.is_some() {
        ctx.db.work_order().id().update(row);
    } else {
        ctx.db.work_order().insert(row);
    }
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Work order {} ({work:?}, tile {tile_id}) set to priority {priority}, enabled {enabled} by operator {}.",
            order.id,
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

#[reducer]
pub fn remove_work_order(ctx: &ReducerContext, order_id: u64) -> Result<(), String> {
    authorize(ctx, RequiredRole::Operator)?;
    let order = ctx
        .db
        .work_order()
        .id()
        .find(order_id)
        .ok_or_else(|| format!("no such work order: {order_id}"))?;
    ctx.db.work_order().id().delete(order_id);
    log_event(
        ctx,
        Severity::Info,
        format!(
            "Work order {order_id} ({:?}, tile {}) removed by operator {}.",
            order.work,
            order.tile_id,
            identity_hex(ctx.sender())
        ),
    );
    Ok(())
}

#[cfg(test)]
mod work_order_validation_tests {
    use super::super::super::sim::{Tile, TileKind, WorkOrder, WorkType};

    #[test]
    fn work_order_input_rejects_non_producing_work_wrong_facility_and_invalid_priorities() {
        let tile = Tile {
            id: 7,
            x: 0,
            y: 0,
            kind: TileKind::Farm,
            enabled: true,
        };
        assert!(WorkOrder::new(&tile, WorkType::None, 2, true).is_err());
        assert!(WorkOrder::new(&tile, WorkType::Mining, 2, true).is_err());
        for priority in [0, 4, u8::MAX] {
            assert!(WorkOrder::new(&tile, WorkType::Farming, priority, false).is_err());
        }
    }

    #[test]
    fn work_order_id_is_stable_across_priority_and_enabled_changes() {
        for work in [
            WorkType::Farming,
            WorkType::Logging,
            WorkType::Mining,
            WorkType::Hunting,
        ] {
            let tile = Tile {
                id: u32::MAX,
                x: 0,
                y: 0,
                kind: work.definition().unwrap().facility,
                enabled: false,
            };
            let original = WorkOrder::new(&tile, work, 1, true).unwrap();
            for priority in 1..=3 {
                for enabled in [false, true] {
                    let order = WorkOrder::new(&tile, work, priority, enabled).unwrap();
                    assert_eq!(order.id, original.id);
                    assert_eq!(order.tile_id, tile.id);
                    assert_eq!(order.work, work);
                    assert_eq!(order.priority, priority);
                    assert_eq!(order.enabled, enabled);
                }
            }
        }
    }
}
