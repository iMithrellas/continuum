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
        let paths = reference_paths(&g, Cell(1, 1, 0), body);
        let mut nav = Navigation::default();
        let cached = nav.reachable(&g, 1, Cell(1, 1, 0), body);
        let packed = Reachability::build(cached.graph.clone(), Cell(1, 1, 0));
        packed.search.borrow_mut().packed = true;
        for z in g.min_z..=g.max_z {
            for y in 0..g.height {
                for x in 0..g.width {
                    let cell = Cell(x, y, z);
                    assert_eq!(
                        cached.get(&cell),
                        reference.get(&cell).copied(),
                        "{body:?}, {cell:?}"
                    );
                    assert_eq!(cached.route(cell), paths.get(&cell).cloned());
                    assert_eq!(packed.get(&cell), reference.get(&cell).copied());
                    assert_eq!(packed.route(cell), paths.get(&cell).cloned());
                }
            }
        }
    }
}

fn reference_paths(g: &Geometry, start: Cell, body: Body) -> BTreeMap<Cell, VecDeque<Cell>> {
    let mut paths = BTreeMap::new();
    if !g.supported(start, body) {
        return paths;
    }
    paths.insert(start, VecDeque::from([start]));
    let mut queue = VecDeque::from([start]);
    while let Some(p) = queue.pop_front() {
        for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
            let step = i32::from(body.step).min(g.max_z - g.min_z);
            for dz in -step..=step {
                let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                if !paths.contains_key(&q) && g.can_step(p, q, body) {
                    let mut path = paths[&p].clone();
                    path.push_back(q);
                    paths.insert(q, path);
                    queue.push_back(q);
                }
            }
        }
    }
    paths
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
fn lazy_geometry_queries_match_supported_positions_and_edges_with_unknown_chunks() {
    let mut g = Geometry::flat();
    g.width = 18;
    g.height = 5;
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
        let graph = Graph::build(Rc::new(g.clone()), body);
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
        for (&cell, &value) in reference.iter().step_by(1024) {
            assert_eq!(reached.get(&cell), Some(value), "{cell:?}, {body:?}");
        }
        assert!(reached.search.borrow().seen.len() <= MAX_LOCAL_VISITS + 252);
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
    let graph = Rc::new(Graph::build(Rc::new(g.clone()), body));
    let local = Reachability::build(graph.clone(), start);
    let distant_first = Reachability::build(graph, start);
    let near = Cell(12, 8, 0);
    assert_eq!(local.get(&near), reference.get(&near).copied());
    assert!(local.search.borrow().queue.len() < 128);
    assert!(local.search.borrow().queue.len() * 100 < reference.len());
    let visited = local.search.borrow().queue.len();
    assert_eq!(local.get(&Cell(22, 8, 6)), None);
    assert!(local.search.borrow().packed);
    assert_eq!(local.search.borrow().queue.len(), 0);
    assert!(visited < MAX_LOCAL_VISITS);
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
    assert!(local.search.borrow().packed);
    assert!(local.graph.edges.borrow().len() <= MAX_CACHED_GRAPH_NODES);
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

fn sparse_logical_world(size: i32) -> (Geometry, Cell) {
    let mut g = Geometry::flat_with_dimensions(16, 16).unwrap();
    let origin = size / 2;
    g.chunks = std::mem::take(&mut g.chunks)
        .into_iter()
        .map(|(p, chunk)| (Cell(p.0 + origin / 16, p.1 + origin / 16, p.2), chunk))
        .collect();
    g.width = size;
    g.height = size;
    (g, Cell(origin + 4, origin + 4, 0))
}

#[test]
fn nearby_work_and_storage_are_independent_of_logical_world_volume() {
    let mut baseline = None;
    for size in [128, 256, 2048] {
        let (g, start) = sparse_logical_world(size);
        let target = Cell(start.0 + 3, start.1 + 2, 0);
        let mut nav = Navigation::default();
        let begin = std::time::Instant::now();
        let reached = nav.reachable(&g, 1, start, Body::default());
        assert!(reached.graph.edges.borrow().is_empty());
        assert_eq!(reached.search.borrow().seen.len(), 1);
        assert_eq!(
            reached.get(&target),
            Some((5, Cell(start.0 + 1, start.1, 0)))
        );
        let path = nav.route(&g, 1, start, Body::default(), target, start);
        assert_eq!(path.len(), 6);
        let elapsed = begin.elapsed();
        let s = reached.search.borrow();
        let edges = reached.graph.edges.borrow();
        let work = (
            s.head,
            s.seen.len(),
            s.queue.capacity(),
            edges.len(),
            edges.values().map(Vec::len).sum::<usize>(),
            edges.values().map(Vec::capacity).sum::<usize>(),
        );
        eprintln!("sparse_navigation size={size} nearby_us={} expanded={} discovered={} queue_capacity={} edge_records={} hops={} hop_capacity={} snapshot_chunks={}",
            elapsed.as_micros(), work.0, work.1, work.2, work.3, work.4, work.5, g.chunks.len());
        assert!(work.0 < 64 && work.1 < 128);
        assert_eq!(*baseline.get_or_insert(work), work);
        drop(edges);
        drop(s);
        assert!(g.contains(Cell(0, 0, 0)));
        assert_eq!(reached.get(&Cell(0, 0, 0)), None);
        assert_eq!(reached.search.borrow().head, work.0);
        let reference = g.reachable(start, Body::default());
        for (&p, &value) in &reference {
            assert_eq!(reached.get(&p), Some(value));
        }
        assert_eq!(reached.search.borrow().seen.len(), reference.len());
    }
}

#[test]
fn snapshot_is_shared_across_bodies_and_actors_and_old_handles_remain_immutable() {
    let (mut g, start) = sparse_logical_world(2048);
    let mut nav = Navigation::default();
    let a = nav.reachable(&g, 1, start, Body::default());
    let b = nav.reachable(
        &g,
        2,
        start,
        Body {
            height: 2,
            ..Body::default()
        },
    );
    assert!(Rc::ptr_eq(&a.graph.terrain.0, &b.graph.terrain.0));
    let target = Cell(start.0 + 1, start.1, 0);
    g.set(target, STONE);
    let changed = nav.reachable(&g, 1, start, Body::default());
    assert!(!Rc::ptr_eq(&a.graph.terrain.0, &changed.graph.terrain.0));
    assert_eq!(changed.get(&target), None);
    assert_eq!(a.get(&target), Some((1, target)));
}

#[test]
fn saved_alternate_shortest_hop_survives_sparse_route_planning() {
    let (g, start) = sparse_logical_world(2048);
    let mut nav = Navigation::default();
    let target = Cell(start.0 + 2, start.1 + 2, 0);
    let saved = Cell(start.0, start.1 + 1, 0);
    let reached = nav.reachable(&g, 1, start, Body::default());
    assert_eq!(
        reached.get(&target),
        Some((4, Cell(start.0 + 1, start.1, 0)))
    );
    assert!(reached.serves(saved, target));
    assert!(!reached.serves(Cell(start.0 - 1, start.1, 0), target));
    let path = nav.route(&g, 1, start, Body::default(), target, saved);
    assert_eq!(path[1], saved);
    assert_eq!(path.len(), 5);
}

#[test]
fn disconnected_supported_target_exhausts_local_component_without_truncation() {
    let (mut g, start) = sparse_logical_world(2048);
    let island = Geometry::flat_with_dimensions(16, 16).unwrap();
    g.chunks.extend(island.chunks);
    let target = Cell(4, 4, 0);
    assert!(g.supported(target, Body::default()));
    let mut nav = Navigation::default();
    let reached = nav.reachable(&g, 1, start, Body::default());
    assert_eq!(reached.get(&target), None);
    let s = reached.search.borrow();
    assert_eq!(s.head, 256);
    assert_eq!(s.seen.len(), 256);
    drop(s);
    assert_eq!(reached.get(&Cell(5, 5, 0)), None);
    assert_eq!(reached.search.borrow().head, 256);
    assert_eq!(
        reached.distance(Cell(start.0 + 11, start.1 + 11, 0)),
        Some(22)
    );
}

fn plane_terrain(size: i32, gaps: Vec<(i32, i32, i32, i32)>) -> terrain::Terrain {
    let mut g = Geometry::flat_with_dimensions(16, 16).unwrap();
    g.chunks.clear();
    g.width = size;
    g.height = size;
    terrain::Terrain(
        Rc::new(g),
        Some(terrain::PlaneFixture {
            gaps,
            ..Default::default()
        }),
    )
}

#[test]
fn authored_plane_fixture_matches_material_geometry_oracle() {
    let t = plane_terrain(24, vec![(10, 0, 10, 20)]);
    let mut g = Geometry::flat();
    for y in 0..=20 {
        for z in g.min_z..=g.max_z {
            g.set(Cell(10, y, z), AIR);
        }
    }
    for body in [
        Body::default(),
        Body {
            width: 2,
            depth: 3,
            height: 1,
            step: 31,
        },
    ] {
        let reference = reference_paths(&g, Cell(1, 1, 0), body);
        for z in g.min_z..=g.max_z {
            for y in 0..24 {
                for x in 0..24 {
                    assert_eq!(
                        t.supported(Cell(x, y, z), body),
                        g.supported(Cell(x, y, z), body)
                    );
                }
            }
        }
        for (&target, route) in reference.iter().step_by(31) {
            assert_eq!(
                packed::query(&t, body, Cell(1, 1, 0), target).as_ref(),
                Some(route)
            );
        }
    }
}

#[test]
fn cache_budget_transition_keeps_query_order_and_alternate_hops_exact() {
    let body = Body::default();
    let start = Cell(1, 1, 0);
    let t = plane_terrain(128, vec![]);
    let graph = Rc::new(Graph {
        terrain: t,
        body,
        edges: RefCell::new(BTreeMap::new()),
    });
    let a = Reachability::build(graph.clone(), start);
    let b = Reachability::build(graph, start);
    let near = Cell(4, 3, 0);
    let far = Cell(126, 125, 0);
    assert_eq!(a.get(&near), Some((5, Cell(2, 1, 0))));
    assert_eq!(b.get(&far), Some((249, Cell(2, 1, 0))));
    assert_eq!(a.get(&far), b.get(&far));
    assert_eq!(a.get(&near), b.get(&near));
    assert_eq!(a.route(far), b.route(far));
    assert!(a.serves(Cell(1, 2, 0), far));
    assert!(!a.serves(Cell(0, 1, 0), far));
    for reached in [a, b] {
        let s = reached.search.borrow();
        assert!(s.packed);
        assert!(s.seen.len() <= MAX_LOCAL_VISITS + 252 && s.queue.capacity() == 0);
        assert!(s.answers.len() <= MAX_PACKED_ANSWERS);
        assert!(reached.graph.edges.borrow().len() <= MAX_CACHED_GRAPH_NODES);
    }
}

#[test]
fn packed_wide_parent_codes_preserve_large_steps_and_nonzero_vertical_hops() {
    let mut g = Geometry::flat();
    g.width = 8;
    g.height = 6;
    g.max_z = 63;
    for z in 0..4 {
        g.set(Cell(3, 2, z), STONE);
    }
    for z in -6..0 {
        g.set(Cell(4, 3, z), AIR);
    }
    let body = Body {
        height: 1,
        step: u16::MAX,
        ..Body::default()
    };
    let t = terrain::Terrain::new(Rc::new(g.clone()));
    let paths = reference_paths(&g, Cell(1, 1, 0), body);
    assert!(paths.contains_key(&Cell(3, 2, 4)));
    assert!(paths.contains_key(&Cell(4, 3, -6)));
    for (&target, route) in &paths {
        assert_eq!(
            packed::query_with_budget(
                &t,
                body,
                Cell(1, 1, 0),
                target,
                ida::Budget {
                    work: 0,
                    ..Default::default()
                }
            )
            .0
            .as_ref(),
            Some(route)
        );
    }
}

#[test]
fn fully_authored_logical_2048_near_colony_only_allocates_local_cache_records() {
    let graph = Rc::new(Graph {
        terrain: plane_terrain(2048, vec![]),
        body: Body::default(),
        edges: RefCell::new(BTreeMap::new()),
    });
    let reached = Reachability::build(graph, Cell(1024, 1024, 0));
    assert_eq!(
        reached.get(&Cell(1027, 1026, 0)),
        Some((5, Cell(1025, 1024, 0)))
    );
    let s = reached.search.borrow();
    assert!(!s.packed && s.answers.is_empty());
    assert_eq!(s.head, 27);
    assert_eq!(s.seen.len(), 45);
    assert_eq!(s.queue.capacity(), 64);
    assert_eq!(reached.graph.edges.borrow().len(), 27);
}

#[test]
fn packed_2048_far_open_separated_and_island_queries_have_small_retained_payloads() {
    let scenarios = [
        (
            "open_far",
            vec![],
            Cell(0, 0, 0),
            Cell(2047, 2047, 0),
            Some(4094),
            4_194_304usize,
        ),
        (
            "terraced_far",
            vec![],
            Cell(0, 0, 0),
            Cell(2047, 2047, 12),
            Some(4094),
            4_194_304,
        ),
        (
            "separated",
            vec![(1024, 0, 1024, 2047)],
            Cell(16, 16, 0),
            Cell(2040, 2040, 0),
            None,
            2_097_152,
        ),
        (
            "island",
            vec![
                (1919, 1919, 1936, 1919),
                (1919, 1936, 1936, 1936),
                (1919, 1920, 1919, 1935),
                (1936, 1920, 1936, 1935),
            ],
            Cell(16, 16, 0),
            Cell(1928, 1928, 0),
            None,
            0,
        ),
    ];
    for (label, gaps, start, target, distance, expanded_limit) in scenarios {
        let mut t = plane_terrain(2048, gaps);
        if label == "terraced_far" {
            t.1.as_mut().unwrap().terrace_every = Some(256);
        }
        let begin = std::time::Instant::now();
        let (route, work) = packed::query_with_work(&t, Body::default(), start, target);
        assert_eq!(
            route.as_ref().map(|p| p.len() as u32 - 1),
            distance,
            "{label}"
        );
        if let Some(path) = &route {
            assert_eq!(path[1], Cell(1, 0, 0));
            assert_eq!(path.front(), Some(&start));
            assert_eq!(path.back(), Some(&target));
            for pair in path.iter().zip(path.iter().skip(1)) {
                assert!(t.adjacent(*pair.0, *pair.1, Body::default()));
            }
        }
        assert!(work.expanded <= expanded_limit);
        assert!(work.page_bytes <= 4 * 1024 * 1024);
        assert!(work.frontier_capacity * 4 <= 64 * 1024);
        assert!(work.reverse_visits <= 1024);
        eprintln!("packed_navigation {label} size=2048 ms={} expanded={} discovered={} pages={} page_bytes={} frontier_bytes={} reverse_visits={} ida_units={} ida_expanded={} ida_iterations={} ida_peak_path={} ida_stack_bytes={} ida_solved={}", begin.elapsed().as_millis(), work.expanded, work.discovered, work.pages, work.page_bytes, work.frontier_capacity * 4, work.reverse_visits, work.ida.units, work.ida.expanded, work.ida.iterations, work.ida.peak_path, work.ida.stack_bytes, work.ida.solved);
        assert!(work.ida.units <= ida::Budget::default().work);
        assert!(work.ida.peak_path <= ida::Budget::default().path);
        if label == "open_far" || label == "terraced_far" {
            assert!(work.ida.solved);
            assert_eq!(work.ida.expanded, 4095);
            assert_eq!(work.expanded, 0);
            assert_eq!(work.pages, 0);
        }
        if label == "island" {
            assert_eq!(work.reverse_visits, 256);
            assert_eq!(work.expanded, 0);
        }
    }
}
