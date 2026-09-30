use super::*;
use spacetimedb::sats::bsatn;

#[test]
fn paused_additive_load_repairs_default_hops_without_advancing_legacy_state() {
    let mut world = sim::new_world();
    let resources = world.resources.clone();
    let orders = world.work_orders.clone();
    let tiles = world.tiles.clone();
    let clock = world.game_seconds;
    let actor = &mut world.colonists[0];
    actor.position = sim::Position { x: 7, y: 9 };
    actor.movement.target = sim::Position { x: 12, y: 11 };
    actor.movement.progress = 0.375;
    actor.task.activity = sim::Activity::Travelling;
    let mut row = colonist_row(actor);
    row.next_x = 0;
    row.next_y = 0;
    row.next_z = 0;
    world.colonists[0] = colonist_state(bsatn::from_slice(&bsatn::to_vec(&row).unwrap()).unwrap());
    world.geometry = Some(sim::geometry::Geometry::flat());
    world.repair_navigation_hops();
    assert!(sim::step(&mut world, &sim::Tuning::default(), 0.0).is_empty());
    let saved = colonist_row(&world.colonists[0]);
    assert_eq!(
        (saved.x, saved.y, saved.target_x, saved.target_y),
        (7, 9, 12, 11)
    );
    assert_eq!((saved.next_x, saved.next_y, saved.next_z), (8, 9, 0));
    assert_eq!(saved.move_progress, 0.375);
    let loaded = colonist_state(bsatn::from_slice(&bsatn::to_vec(&saved).unwrap()).unwrap());
    assert_eq!(loaded, world.colonists[0]);
    assert_eq!(world.resources, resources);
    assert_eq!(world.work_orders, orders);
    assert_eq!(world.tiles, tiles);
    assert_eq!(world.game_seconds, clock);
    for c in &world.colonists[1..] {
        assert_eq!(
            c.spatial.next,
            sim::geometry::Cell(c.position.x, c.position.y, c.spatial.z)
        );
    }
}

#[test]
fn paused_load_preserves_legitimate_zero_and_noncanonical_equal_length_hops() {
    let mut world = sim::new_world();
    world.geometry = Some(sim::geometry::Geometry::flat());
    world.colonists.truncate(1);
    let c = &mut world.colonists[0];
    c.position = sim::Position { x: 1, y: 0 };
    c.movement.target = sim::Position { x: 0, y: 0 };
    c.task.activity = sim::Activity::Travelling;
    c.spatial.next = sim::geometry::Cell(0, 0, 0);
    c.movement.progress = 0.625;
    world.repair_navigation_hops();
    assert_eq!(world.colonists[0].movement.progress, 0.625);
    assert_eq!(
        world.colonists[0].spatial.next,
        sim::geometry::Cell(0, 0, 0)
    );
    let c = &mut world.colonists[0];
    c.position = sim::Position { x: 3, y: 5 };
    c.movement.target = sim::Position { x: 5, y: 7 };
    c.spatial.next = sim::geometry::Cell(3, 6, 0);
    world.repair_navigation_hops();
    assert_eq!(world.colonists[0].movement.progress, 0.625);
    assert_eq!(
        world.colonists[0].spatial.next,
        sim::geometry::Cell(3, 6, 0)
    );
    world.colonists[0].spatial.next = sim::geometry::Cell(20, 20, 0);
    world.repair_navigation_hops();
    assert_eq!(
        world.colonists[0].spatial.next,
        sim::geometry::Cell(4, 5, 0)
    );
    assert_eq!(world.colonists[0].movement.progress, 0.0);
}

#[test]
fn component_mapping_preserves_every_persisted_colonist_field() {
    for amount in [0.0, 12.5] {
        let row = Colonist {
            id: u64::MAX,
            name: "Mapping fixture".into(),
            x: 3,
            y: 5,
            move_progress: 0.375,
            target_x: 17,
            target_y: 19,
            activity: sim::Activity::Travelling,
            work: sim::WorkType::Hunting,
            haul_role: sim::HaulRole::Hauler,
            carried_kind: sim::ResourceKind::Meat,
            carried_amount: amount,
            goal: sim::Goal::Haul,
            hunger: 21.0,
            fatigue: 32.0,
            recreation: 43.0,
            mood: 54.0,
            productivity: 65.0,
            sleep_hours: 7.25,
            last_sleep_quality: 0.625,
            z: -3,
            target_z: 7,
            body_width: 2,
            body_depth: 3,
            clearance_height: 5,
            max_step_height: 2,
            next_x: 4,
            next_y: 6,
            next_z: -2,
        };
        let state = sim::Colonist {
            id: u64::MAX,
            name: "Mapping fixture".into(),
            spatial: sim::geometry::Spatial {
                z: -3,
                target_z: 7,
                next: sim::geometry::Cell(4, 6, -2),
                body: sim::geometry::Body {
                    width: 2,
                    depth: 3,
                    height: 5,
                    step: 2,
                },
            },
            position: sim::Position { x: 3, y: 5 },
            movement: sim::Movement {
                target: sim::Position { x: 17, y: 19 },
                progress: 0.375,
            },
            task: sim::ActivityState {
                activity: sim::Activity::Travelling,
                goal: sim::Goal::Haul,
            },
            assignment: sim::WorkAssignment {
                work: sim::WorkType::Hunting,
                haul_role: sim::HaulRole::Hauler,
            },
            cargo: sim::Cargo {
                kind: sim::ResourceKind::Meat,
                amount,
            },
            needs: sim::Needs {
                hunger: 21.0,
                fatigue: 32.0,
                recreation: 43.0,
            },
            wellbeing: sim::Wellbeing {
                mood: 54.0,
                productivity: 65.0,
            },
            rest: sim::Rest {
                hours: 7.25,
                last_quality: 0.625,
            },
        };
        let saved = colonist_row(&state);
        macro_rules! unchanged {
            ($($field:ident),+ $(,)?) => { $(assert_eq!(saved.$field, row.$field, stringify!($field));)+ };
        }
        unchanged!(
            id,
            name,
            x,
            y,
            move_progress,
            target_x,
            target_y,
            activity,
            work,
            haul_role,
            carried_kind,
            carried_amount,
            goal,
            hunger,
            fatigue,
            recreation,
            mood,
            productivity,
            sleep_hours,
            last_sleep_quality,
            z,
            target_z,
            body_width,
            body_depth,
            clearance_height,
            max_step_height,
            next_x,
            next_y,
            next_z
        );
        assert_eq!(colonist_state(row), state);
        assert_eq!(colonist_state(saved), state);
        assert_eq!(state.is_carrying(), amount > 0.0);
    }
}

#[test]
fn multivoxel_tile_and_elevated_ground_stack_roundtrip_preserve_all_fields() {
    let t = sim::Tile {
        id: u32::MAX,
        x: 8,
        y: 11,
        z: -9,
        kind: sim::TileKind::Farm,
        enabled: false,
        width: 3,
        depth: 2,
        clearance_height: 7,
    };
    let row: Tile = bsatn::from_slice(&bsatn::to_vec(&tile_row(&t)).unwrap()).unwrap();
    assert_eq!(tile_state(row), t);
    let s = sim::ItemStack {
        id: sim::stack_id(t.id, sim::ResourceKind::Food),
        tile_id: t.id,
        x: 8,
        y: 11,
        z: -9,
        kind: sim::ResourceKind::Food,
        amount: 0.625,
    };
    let row: ItemStack = bsatn::from_slice(&bsatn::to_vec(&stack_row(&s)).unwrap()).unwrap();
    assert_eq!(stack_state(row), s);
}

#[test]
fn geometry_and_material_wire_roundtrip_preserve_bounds_and_si_properties() {
    let g = WorldGeometry {
        id: 0,
        width: 24,
        height: 24,
        min_z: -16,
        max_z: 15,
    };
    let saved: WorldGeometry = bsatn::from_slice(&bsatn::to_vec(&g).unwrap()).unwrap();
    assert_eq!(
        (
            saved.id,
            saved.width,
            saved.height,
            saved.min_z,
            saved.max_z
        ),
        (g.id, g.width, g.height, g.min_z, g.max_z)
    );
    let m = TerrainMaterial {
        id: 2,
        name: "stone".into(),
        density: 2700.0,
        strength: 100_000_000.0,
        thermal_conductivity: 2.5,
        specific_heat_capacity: 790.0,
        opaque: true,
    };
    let saved: TerrainMaterial = bsatn::from_slice(&bsatn::to_vec(&m).unwrap()).unwrap();
    assert_eq!(saved.id, m.id);
    assert_eq!(saved.name, m.name);
    assert_eq!(saved.density, m.density);
    assert_eq!(saved.strength, m.strength);
    assert_eq!(saved.thermal_conductivity, m.thermal_conductivity);
    assert_eq!(saved.specific_heat_capacity, m.specific_heat_capacity);
    assert_eq!(saved.opaque, m.opaque);
}
