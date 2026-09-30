use super::*;
use crate::sim::geometry::{AIR, STONE};

#[test]
fn cached_sparse_routes_match_reference_bfs_for_all_supported_positions_and_bodies() {
    let mut g = Geometry::flat();
    g.width = 8;
    g.height = 6;
    for z in 0..4 {
        g.set(Cell(3, 2, z), STONE);
    }
    g.set(Cell(5, 2, 0), STONE);
    g.set(Cell(5, 3, 0), STONE);
    for z in -4..0 {
        g.set(Cell(2, 4, z), AIR);
    }
    for body in [
        Body::default(),
        Body {
            width: 2,
            depth: 2,
            ..Body::default()
        },
        Body {
            height: 2,
            step: 2,
            ..Body::default()
        },
    ] {
        let reference = g.reachable(Cell(1, 1, 0), body);
        let mut nav = Navigation::default();
        let cached = nav.reachable(&g, 1, Cell(1, 1, 0), body);
        for z in g.min_z..=g.max_z {
            for y in 0..g.height {
                for x in 0..g.width {
                    let cell = Cell(x, y, z);
                    assert_eq!(
                        cached.get(&cell),
                        reference.get(&cell).copied(),
                        "{body:?}, {cell:?}"
                    );
                }
            }
        }
    }
}

#[test]
fn every_real_voxel_change_invalidates_even_same_chunk_same_public_revision() {
    let mut g = Geometry::flat();
    let mut nav = Navigation::default();
    let body = Body::default();
    let start = Cell(1, 1, 0);
    let target = Cell(2, 1, 0);
    assert!(nav.reachable(&g, 1, start, body).contains_key(&target));
    g.set(Cell(2, 1, 3), STONE);
    assert!(!nav.reachable(&g, 1, start, body).contains_key(&target));
    let revision = g.chunks[&Cell(0, 0, 0)].revision;
    g.set(Cell(2, 1, 3), AIR);
    assert_eq!(g.chunks[&Cell(0, 0, 0)].revision, revision);
    assert!(nav.reachable(&g, 1, start, body).contains_key(&target));
    assert_eq!(nav.graph_builds, 3);
    let builds = nav.graph_builds;
    assert!(!g.set(Cell(2, 1, 3), AIR));
    nav.reachable(&g, 1, start, body);
    assert_eq!(nav.graph_builds, builds);
}

#[test]
fn actor_local_search_and_planned_route_are_reused_across_decisions_and_hops() {
    let g = Geometry::flat();
    let mut nav = Navigation::default();
    let b = Body::default();
    let start = Cell(1, 1, 0);
    let target = Cell(12, 11, 0);
    for _ in 0..10 {
        nav.reachable(&g, 1, start, b);
    }
    assert_eq!(nav.searches, 1);
    assert_eq!(nav.graph_builds, 1);
    let route = nav.route(&g, 1, start, b, target, start);
    nav.consume_route(1, 3);
    let next_start = route[3];
    let continuing = nav.route(&g, 1, next_start, b, target, route[4]);
    assert_eq!(continuing.front(), Some(&next_start));
    assert_eq!(continuing.back(), Some(&target));
    assert_eq!(nav.searches, 1);
    assert_eq!(nav.route_builds, 1);
    nav.reachable(&g, 1, next_start, b);
    assert_eq!(nav.searches, 2);
}

#[test]
fn cache_storage_is_bounded_by_bodies_and_actor_ids_not_visited_origins() {
    let g = Geometry::flat();
    let mut nav = Navigation::default();
    for id in 0..300 {
        let b = Body {
            height: (id % 10 + 1) as u16,
            ..Body::default()
        };
        let start = Cell((id % 24) as i32, (id / 24 % 24) as i32, 0);
        nav.reachable(&g, id, start, b);
        nav.route(&g, id, start, b, Cell(0, 0, 0), start);
        let (bodies, actors, routes) = nav.cached_counts();
        assert!(
            bodies <= MAX_CACHED_BODIES
                && actors <= MAX_CACHED_ACTORS
                && routes <= MAX_CACHED_ACTORS
        );
    }
    let mut nav = Navigation::default();
    for id in 0..300 {
        nav.route(
            &g,
            id,
            Cell(1, 1, 0),
            Body::default(),
            Cell(2, 2, 0),
            Cell(1, 1, 0),
        );
    }
    assert_eq!(
        nav.cached_counts(),
        (1, MAX_CACHED_ACTORS, MAX_CACHED_ACTORS)
    );
}

#[test]
fn compact_clearance_matches_supported_positions_and_edges_with_unknown_chunks() {
    let mut g = Geometry::flat();
    g.width = 18;
    g.height = 5;
    // The missing negative chunk is not air or support. Use arbitrary non-air
    // material IDs too: navigation must not depend on the material registry.
    g.chunks.remove(&Cell(1, 0, -1));
    g.set(Cell(15, 2, 0), u16::MAX);
    for z in -5..0 {
        g.set(Cell(3, 2, z), AIR);
    }
    g.set(Cell(4, 2, 0), STONE);
    g.set(Cell(5, 2, 3), STONE);
    for body in [
        Body::default(),
        Body {
            width: 2,
            depth: 2,
            height: 2,
            step: 3,
        },
        Body {
            height: 1,
            step: 7,
            ..Body::default()
        },
        Body {
            height: 16,
            ..Body::default()
        },
        Body {
            width: 0,
            ..Body::default()
        },
        Body {
            height: u16::MAX,
            ..Body::default()
        },
    ] {
        let graph = Graph::build(&g, body);
        for z in g.min_z..=g.max_z {
            for y in 0..g.height {
                for x in 0..g.width {
                    let p = Cell(x, y, z);
                    assert_eq!(
                        graph.node(p).is_some(),
                        g.supported(p, body),
                        "{p:?}, {body:?}"
                    );
                    if graph.node(p).is_some() {
                        for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                            for dz in -i32::from(body.step)..=i32::from(body.step) {
                                let q = Cell(x + dx, y + dy, z + dz);
                                assert_eq!(
                                    graph.adjacent(p, q),
                                    g.can_step(p, q, body),
                                    "{p:?}->{q:?}, {body:?}"
                                );
                            }
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn large_world_cached_distances_and_first_hops_match_reference_and_expansion_invalidates() {
    let mut g = Geometry::flat();
    let start = Cell(10, 7, 0);
    let mut nav = Navigation::default();
    assert!(nav
        .reachable(&g, 1, start, Body::default())
        .get(&Cell(127, 127, 0))
        .is_none());
    g.expand(128, 128).unwrap();
    for z in 0..6 {
        g.set(Cell(22, 8, z), STONE);
    }
    for body in [
        Body::default(),
        Body {
            width: 2,
            depth: 3,
            height: 7,
            step: 2,
        },
    ] {
        let reference = g.reachable(start, body);
        let reached = nav.reachable(&g, 1, start, body);
        for (&cell, &value) in &reference {
            assert_eq!(reached.get(&cell), Some(value), "{cell:?}, {body:?}");
        }
        for &cell in &reached.graph.cells {
            assert!(g.supported(cell, body));
            assert_eq!(
                reached.get(&cell),
                reference.get(&cell).copied(),
                "{cell:?}, {body:?}"
            );
        }
        for outside in [
            Cell(128, 0, 0),
            Cell(0, 128, 0),
            Cell(-1, 0, 0),
            Cell(0, 0, 16),
            Cell(0, 0, -17),
        ] {
            assert_eq!(reached.get(&outside), None);
        }
        assert_eq!(reached.distance(Cell(126, 125, 0)), Some(234));
    }
    assert_eq!(nav.graph_builds, 3);
}

#[test]
fn lazy_queries_avoid_distant_land_and_query_order_cannot_change_canonical_paths() {
    let g = Geometry::seeded();
    let start = Cell(10, 7, 0);
    let body = Body::default();
    let reference = g.reachable(start, body);
    let graph = Rc::new(Graph::build(&g, body));
    let local = Reachability::build(graph.clone(), start);
    let distant_first = Reachability::build(graph, start);
    let near = Cell(12, 8, 0);
    assert_eq!(local.get(&near), reference.get(&near).copied());
    assert!(local.search.borrow().queue.len() < 128);
    assert!(local.search.borrow().queue.len() * 100 < reference.len());
    let visited = local.search.borrow().queue.len();
    assert_eq!(local.get(&Cell(22, 8, 6)), None); // disconnected hillside top
    assert_eq!(local.search.borrow().queue.len(), visited);
    let targets = [
        near,
        Cell(127, 127, 0),
        Cell(22, 8, 6),
        Cell(2, 2, 0),
        Cell(19, 4, 0),
    ];
    for p in targets.into_iter().rev() {
        assert_eq!(distant_first.get(&p), reference.get(&p).copied());
    }
    for p in targets {
        assert_eq!(local.get(&p), reference.get(&p).copied());
        assert_eq!(local.route(p), distant_first.route(p));
    }
    assert_eq!(local.search.borrow().queue.len(), reference.len());
}

#[test]
fn larger_physical_world_still_executes_actors_and_shared_goods_in_durable_id_order() {
    let mut ordered = crate::sim::new_world();
    ordered.geometry = Some(Geometry::seeded());
    let mut permuted = ordered.clone();
    permuted.colonists.reverse();
    permuted.tiles.reverse();
    permuted.work_orders.reverse();
    let tuning = crate::sim::Tuning::default();
    let events = crate::sim::step(&mut ordered, &tuning, 3600.0);
    let shuffled_events = crate::sim::step(&mut permuted, &tuning, 3600.0);
    assert_eq!(events, shuffled_events);
    permuted.colonists.sort_by_key(|c| c.id);
    permuted.tiles.sort_by_key(|t| t.id);
    permuted.work_orders.sort_by_key(|o| o.id);
    assert_eq!(ordered, permuted);
}
