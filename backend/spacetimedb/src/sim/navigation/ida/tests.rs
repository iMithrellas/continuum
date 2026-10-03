use super::*;
use crate::sim::geometry::{Geometry, AIR, STONE};
use crate::sim::navigation::{packed, terrain::PlaneFixture};
use std::collections::BTreeMap;
use std::rc::Rc;

fn plane(size: i32, fixture: PlaneFixture) -> Terrain {
    Terrain(
        Rc::new(Geometry::flat_with_dimensions(size, size).unwrap()),
        Some(fixture),
    )
}

/// Independent ordered BFS oracle, without IDA heuristics or packed parent codes.
fn oracle(t: &Terrain, start: Cell, body: Body) -> BTreeMap<Cell, VecDeque<Cell>> {
    let mut routes = BTreeMap::new();
    if !t.supported(start, body) {
        return routes;
    }
    routes.insert(start, VecDeque::from([start]));
    let mut queue = VecDeque::from([start]);
    let step = i32::from(body.step).min(t.0.max_z - t.0.min_z);
    while let Some(p) = queue.pop_front() {
        for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
            for dz in -step..=step {
                let q = Cell(p.0 + dx, p.1 + dy, p.2 + dz);
                if !routes.contains_key(&q) && t.adjacent(p, q, body) {
                    let mut path = routes[&p].clone();
                    path.push_back(q);
                    routes.insert(q, path);
                    queue.push_back(q);
                }
            }
        }
    }
    routes
}

#[test]
fn exhaustive_three_square_floor_masks_match_canonical_bfs() {
    let body = Body {
        height: 1,
        step: 0,
        ..Body::default()
    };
    for mask in 0..512u32 {
        let gaps = (0..9)
            .filter(|n| mask & (1 << n) == 0)
            .map(|n| (n % 3, n / 3, n % 3, n / 3))
            .collect();
        let t = plane(
            3,
            PlaneFixture {
                gaps,
                ..Default::default()
            },
        );
        for sy in 0..3 {
            for sx in 0..3 {
                let start = Cell(sx, sy, 0);
                let reference = oracle(&t, start, body);
                for y in 0..3 {
                    for x in 0..3 {
                        let target = Cell(x, y, 0);
                        let (path, _) = try_path(&t, body, start, target, Budget::default());
                        assert_eq!(
                            path.as_ref(),
                            reference.get(&target),
                            "mask={mask} {start:?}->{target:?}"
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn exhaustive_two_square_directed_edge_sets_match_canonical_bfs() {
    let body = Body {
        height: 1,
        step: 0,
        ..Body::default()
    };
    let mut edges = Vec::new();
    for y in 0..2 {
        for x in 0..2 {
            for (dx, dy) in [(1, 0), (0, 1), (-1, 0), (0, -1)] {
                if (0..2).contains(&(x + dx)) && (0..2).contains(&(y + dy)) {
                    edges.push((Cell(x, y, 0), Cell(x + dx, y + dy, 0)));
                }
            }
        }
    }
    assert_eq!(edges.len(), 8);
    for mask in 0..256u32 {
        let forbidden_edges = edges
            .iter()
            .enumerate()
            .filter(|(n, _)| mask & (1 << n) == 0)
            .map(|(_, e)| *e)
            .collect();
        let t = plane(
            2,
            PlaneFixture {
                forbidden_edges,
                ..Default::default()
            },
        );
        for start in [Cell(0, 0, 0), Cell(1, 0, 0), Cell(0, 1, 0), Cell(1, 1, 0)] {
            let reference = oracle(&t, start, body);
            for target in [Cell(1, 1, 0), Cell(0, 1, 0), Cell(1, 0, 0), Cell(0, 0, 0)] {
                assert_eq!(
                    try_path(&t, body, start, target, Budget::default())
                        .0
                        .as_ref(),
                    reference.get(&target),
                    "mask={mask} {start:?}->{target:?}"
                );
                assert_eq!(
                    packed::query(&t, body, start, target).as_ref(),
                    reference.get(&target)
                );
            }
        }
    }
}

#[test]
fn cave_footprint_steps_unknowns_and_directed_vertical_edges_match_bfs() {
    let mut g = Geometry::flat();
    g.width = 18;
    g.height = 6;
    g.chunks.remove(&Cell(1, 0, -1));
    for z in 0..4 {
        g.set(Cell(3, 2, z), STONE);
    }
    for x in 1..6 {
        for z in -6..-2 {
            g.set(Cell(x, 3, z), AIR);
        }
    }
    for z in -5..0 {
        g.set(Cell(2, 4, z), AIR);
    }
    let t = Terrain(
        Rc::new(g),
        Some(PlaneFixture {
            use_material_geometry: true,
            forbidden_edges: vec![
                (Cell(2, 2, 0), Cell(3, 2, 4)),
                (Cell(2, 3, -6), Cell(1, 3, -6)),
            ],
            ..Default::default()
        }),
    );
    assert_eq!(t.0.material(Cell(16, 1, -1)), None);
    assert!(!t.supported(Cell(16, 1, 0), Body::default()));
    for body in [
        Body::default(),
        Body {
            width: 2,
            depth: 2,
            height: 2,
            step: 2,
        },
        Body {
            height: 1,
            step: 7,
            ..Body::default()
        },
        Body {
            width: 0,
            ..Body::default()
        },
    ] {
        for start in [Cell(1, 1, 0), Cell(1, 3, -6), Cell(3, 2, 4), Cell(17, 5, 0)] {
            let reference = oracle(&t, start, body);
            for z in t.0.min_z..=t.0.max_z {
                for y in 0..6 {
                    for x in 0..18 {
                        let target = Cell(x, y, z);
                        if !t.supported(target, body) {
                            continue;
                        }
                        let (path, work) = packed::query_with_work(&t, body, start, target);
                        assert_eq!(
                            path.as_ref(),
                            reference.get(&target),
                            "{body:?} {start:?}->{target:?}"
                        );
                        assert!(work.ida.units <= Budget::default().work);
                        let disabled = Budget {
                            work: 0,
                            ..Budget::default()
                        };
                        assert_eq!(
                            packed::query_with_budget(&t, body, start, target, disabled).0,
                            path
                        );
                    }
                }
            }
        }
    }
}

#[test]
fn fully_exhausted_thresholds_and_all_budget_limits_fall_back_without_false_rejection() {
    let t = plane(
        6,
        PlaneFixture {
            gaps: vec![(2, 0, 2, 3)],
            ..Default::default()
        },
    );
    let start = Cell(1, 1, 0);
    let target = Cell(4, 1, 0);
    let body = Body {
        height: 1,
        step: 0,
        ..Body::default()
    };
    let reference = oracle(&t, start, body);
    let (path, work) = try_path(&t, body, start, target, Budget::default());
    assert_eq!(path.as_ref(), reference.get(&target));
    assert!(work.iterations > 1);
    for budget in [
        Budget {
            work: 0,
            ..Budget::default()
        },
        Budget {
            work: 1,
            ..Budget::default()
        },
        Budget {
            path: 2,
            ..Budget::default()
        },
        Budget {
            iterations: 0,
            ..Budget::default()
        },
        Budget {
            iterations: 1,
            ..Budget::default()
        },
    ] {
        let (path, work) = packed::query_with_budget(&t, body, start, target, budget);
        assert_eq!(path.as_ref(), reference.get(&target));
        assert!(!work.ida.solved && work.pages > 0);
        assert!(work.ida.units <= budget.work);
        assert!(work.ida.peak_path <= budget.path);
        assert!(work.ida.iterations <= budget.iterations);
    }
}

#[test]
fn authored_terrace_fixture_matches_real_material_clearance_and_canonical_routes() {
    let t = plane(
        6,
        PlaneFixture {
            terrace_every: Some(3),
            ..Default::default()
        },
    );
    let mut g = Geometry::flat_with_dimensions(6, 6).unwrap();
    for y in 0..6 {
        for x in 0..6 {
            for z in 0..(x + y) / 3 {
                g.set(Cell(x, y, z), STONE);
            }
        }
    }
    let material = Terrain::new(Rc::new(g));
    for body in [
        Body::default(),
        Body {
            width: 2,
            depth: 2,
            height: 2,
            step: 2,
        },
    ] {
        for z in -1..8 {
            for y in 0..6 {
                for x in 0..6 {
                    assert_eq!(
                        t.supported(Cell(x, y, z), body),
                        material.supported(Cell(x, y, z), body)
                    );
                }
            }
        }
        for start in [Cell(0, 0, 0), Cell(3, 3, 2), Cell(5, 5, 3)] {
            let reference = oracle(&material, start, body);
            for y in 0..6 {
                for x in 0..6 {
                    let target = Cell(x, y, (x + y) / 3);
                    assert_eq!(
                        packed::query(&t, body, start, target).as_ref(),
                        reference.get(&target)
                    );
                }
            }
        }
    }
}
