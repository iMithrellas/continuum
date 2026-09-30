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
