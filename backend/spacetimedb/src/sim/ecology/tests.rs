use super::*;
use crate::sim::{
    self, geometry::Geometry, logistics, Colonist, HaulRole, Tile, TileKind, Tuning, World,
};

const SITE_ID: u32 = 901;

fn fields(value: f32) -> TerrainFields {
    TerrainFields {
        soil_fertility: value,
        forest_density: value,
        moisture: value,
    }
}

fn close(actual: f32, expected: f32) {
    assert!((actual - expected).abs() < 0.0001, "{actual} != {expected}");
}

fn production_world(work: WorkType, terrain: Option<TerrainFields>) -> World {
    let mut world = sim::new_world();
    world.geometry = Some(Geometry::flat_with_dimensions(2, 1).unwrap());
    world.tiles = vec![
        Tile {
            id: SITE_ID,
            x: 0,
            y: 0,
            z: 0,
            kind: work.definition().unwrap().facility,
            enabled: true,
            width: 1,
            depth: 1,
            clearance_height: 4,
        },
        Tile {
            id: 77,
            x: 1,
            y: 0,
            z: 0,
            kind: TileKind::Storage,
            enabled: true,
            width: 1,
            depth: 1,
            clearance_height: 4,
        },
    ];
    world.work_orders = sim::default_work_orders(&world.tiles);
    let mut worker = Colonist::new(43, "Producer", 0, 0);
    worker.assignment.work = work;
    worker.assignment.haul_role = HaulRole::Both;
    worker.wellbeing.productivity = 100.0;
    world.colonists = vec![worker];
    if let Some(terrain) = terrain {
        world.ecology.insert(SITE_ID, terrain);
    }
    world
}

#[test]
fn formula_uses_both_farming_fields_and_only_forest_for_forest_work() {
    let terrain = TerrainFields {
        soil_fertility: 0.8,
        moisture: 0.25,
        forest_density: 0.9,
    };
    close(
        production_multiplier(WorkType::Farming, Some(&terrain)),
        0.7,
    );
    for work in [WorkType::Logging, WorkType::Hunting] {
        close(production_multiplier(work, Some(&terrain)), 1.4);
    }
    for work in [WorkType::Mining, WorkType::None] {
        assert_eq!(production_multiplier(work, Some(&terrain)), 1.0);
    }
    for terrain in [
        TerrainFields {
            moisture: 0.0,
            ..fields(1.0)
        },
        TerrainFields {
            soil_fertility: 0.0,
            ..fields(1.0)
        },
    ] {
        assert_eq!(
            production_multiplier(WorkType::Farming, Some(&terrain)),
            0.5
        );
    }
}

#[test]
fn extrema_and_invalid_fields_are_finite_bounded_and_conservative() {
    let extremes = [
        f32::NAN,
        f32::INFINITY,
        f32::NEG_INFINITY,
        f32::MIN,
        -1.0,
        0.0,
        0.5,
        1.0,
        f32::MAX,
    ];
    for fertility in extremes {
        for moisture in extremes {
            for forest in extremes {
                let terrain = TerrainFields {
                    soil_fertility: fertility,
                    moisture,
                    forest_density: forest,
                };
                for work in [
                    WorkType::Farming,
                    WorkType::Logging,
                    WorkType::Hunting,
                    WorkType::Mining,
                    WorkType::None,
                ] {
                    let multiplier = production_multiplier(work, Some(&terrain));
                    assert!(multiplier.is_finite());
                    assert!((0.5..=1.5).contains(&multiplier));
                }
            }
        }
    }
    for value in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, -1.0] {
        for work in [WorkType::Farming, WorkType::Logging, WorkType::Hunting] {
            assert_eq!(production_multiplier(work, Some(&fields(value))), 0.5);
        }
    }
    assert_eq!(
        production_multiplier(WorkType::Farming, Some(&fields(f32::MAX))),
        1.5
    );
}

#[test]
fn rich_and_poor_live_sites_change_ground_output_not_stores_and_hauling_conserves() {
    let tuning = Tuning::default();
    for work in [WorkType::Farming, WorkType::Logging, WorkType::Hunting] {
        let output = work.definition().unwrap().output;
        let baseline = tuning.output_per_hour(output);
        let mut poor = production_world(work, Some(fields(0.0)));
        let mut rich = production_world(work, Some(fields(1.0)));
        let stored = rich.resources.amount(output);
        logistics::step_work(&mut poor, 0, &tuning, 1.0);
        logistics::step_work(&mut rich, 0, &tuning, 1.0);
        close(poor.stack_amount(SITE_ID, output), baseline * 0.5);
        close(rich.stack_amount(SITE_ID, output), baseline * 1.5);
        assert_eq!(poor.resources.amount(output), stored);
        assert_eq!(rich.resources.amount(output), stored);
        let produced = rich.stack_amount(SITE_ID, output);
        rich.work_orders
            .iter_mut()
            .for_each(|order| order.enabled = false);
        while rich.stack_amount(SITE_ID, output) > 0.0 {
            logistics::step_haul(&mut rich, 0, &tuning);
            assert!(rich.colonists[0].cargo.amount > 0.0);
            close(
                rich.stack_amount(SITE_ID, output)
                    + rich.colonists[0].cargo.amount
                    + rich.resources.amount(output)
                    - stored,
                produced,
            );
            rich.colonists[0].position.x = 1;
            logistics::step_haul(&mut rich, 0, &tuning);
            assert_eq!(rich.colonists[0].cargo.amount, 0.0);
            close(
                rich.stack_amount(SITE_ID, output) + rich.resources.amount(output) - stored,
                produced,
            );
            rich.colonists[0].position.x = 0;
        }
        close(rich.resources.amount(output) - stored, produced);
    }
}

#[test]
fn row_order_and_actor_identity_do_not_change_durable_tile_mapping() {
    let rows = [
        (77, fields(0.0)),
        (SITE_ID, fields(1.0)),
        (12, fields(0.25)),
    ];
    let mut forward = production_world(WorkType::Farming, None);
    forward.ecology = rows.into_iter().collect();
    let mut reverse = forward.clone();
    reverse.ecology = rows.into_iter().rev().collect();
    reverse.tiles.reverse();
    reverse.colonists[0].id = 1234;
    assert_eq!(forward.ecology, reverse.ecology);
    let tuning = Tuning::default();
    logistics::step_work(&mut forward, 0, &tuning, 1.0);
    logistics::step_work(&mut reverse, 0, &tuning, 1.0);
    assert_eq!(forward.stacks, reverse.stacks);
    close(forward.stacks[0].amount, tuning.output_food_per_hour * 1.5);
}

#[test]
fn missing_is_exactly_neutral_and_permissions_remain_authoritative() {
    assert!(sim::new_world().ecology.is_empty());
    let tuning = Tuning::default();
    for work in [
        WorkType::Farming,
        WorkType::Logging,
        WorkType::Hunting,
        WorkType::Mining,
        WorkType::None,
    ] {
        assert_eq!(production_multiplier(work, None), 1.0);
    }
    for work in [WorkType::Farming, WorkType::Logging, WorkType::Hunting] {
        let mut world = production_world(work, None);
        let output = work.definition().unwrap().output;
        logistics::step_work(&mut world, 0, &tuning, 1.0);
        assert_eq!(
            world.stack_amount(SITE_ID, output),
            tuning.output_per_hour(output)
        );
        for restriction in 0..3 {
            let mut world = production_world(work, Some(fields(1.0)));
            match restriction {
                0 => world.tiles[0].enabled = false,
                1 => world.work_orders.clear(),
                _ => world.colonists[0].assignment.haul_role = HaulRole::Hauler,
            }
            logistics::step_work(&mut world, 0, &tuning, 1.0);
            assert!(world.stacks.is_empty());
        }
    }
}
