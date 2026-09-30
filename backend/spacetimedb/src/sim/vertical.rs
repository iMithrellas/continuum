//! Live geometry adapters for decisions, finite extraction, and movement.
use super::geometry::{Body, Cell, AIR};
use super::{Activity, Goal, ResourceKind, Tile, TileKind, Tuning, WorkType, World};

impl Tile {
    pub fn base(&self) -> Cell {
        Cell(self.x, self.y, self.z)
    }
    pub fn body(&self) -> Body {
        Body {
            width: self.width,
            depth: self.depth,
            height: self.clearance_height,
            step: 0,
        }
    }
    pub fn occupies(&self, c: Cell) -> bool {
        self.kind != TileKind::Empty
            && c.0 >= self.x
            && c.0 < self.x + i32::from(self.width)
            && c.1 >= self.y
            && c.1 < self.y + i32::from(self.depth)
            && c.2 >= self.z
            && c.2 < self.z + i32::from(self.clearance_height)
    }
    pub fn protects_support(&self, c: Cell) -> bool {
        self.kind != TileKind::Empty
            && c.2 == self.z - 1
            && c.0 >= self.x
            && c.0 < self.x + i32::from(self.width)
            && c.1 >= self.y
            && c.1 < self.y + i32::from(self.depth)
    }
}

impl World {
    /// Validate saved interpolation independently of the clock. In particular,
    /// zero is a valid neighbour, not a sentinel indicating an unmigrated actor.
    pub fn repair_navigation_hops(&mut self) {
        let Some(_) = &self.geometry else {
            return;
        };
        for index in 0..self.colonists.len() {
            let actor = &self.colonists[index];
            let start = Cell(actor.position.x, actor.position.y, actor.spatial.z);
            let target = Cell(
                actor.movement.target.x,
                actor.movement.target.y,
                actor.spatial.target_z,
            );
            if actor.task.activity != Activity::Travelling || start == target {
                let actor = &mut self.colonists[index];
                actor.spatial.next = start;
                actor.movement.progress = 0.0;
                continue;
            }
            let reached = self.actor_reachability(index);
            let Some((_, hop)) = reached.get(&target) else {
                let actor = &mut self.colonists[index];
                actor.spatial.next = start;
                actor.movement.progress = 0.0;
                continue;
            };
            let saved = actor.spatial.next;
            let valid = reached.serves(saved, target);
            if !valid {
                let actor = &mut self.colonists[index];
                // Old flat movement used this exact hop. Keep its fractional
                // progress when only the appended/default next field was missing.
                let legacy = if start.0 != target.0 {
                    Cell(start.0 + (target.0 - start.0).signum(), start.1, start.2)
                } else {
                    Cell(start.0, start.1 + (target.1 - start.1).signum(), start.2)
                };
                if saved == Cell(0, 0, 0) && reached.serves(legacy, target) {
                    // A legacy x-first hop can differ from the BFS tie-breaker
                    // while still being an equally short, physically valid route.
                    actor.spatial.next = legacy;
                } else {
                    actor.movement.progress = 0.0;
                    actor.spatial.next = hop;
                }
            }
        }
    }

    pub fn actor_cell(&self, index: usize) -> Cell {
        let c = &self.colonists[index];
        Cell(c.position.x, c.position.y, c.spatial.z)
    }
    pub fn tile_at_elevation(&self, x: i32, y: i32, z: i32) -> Option<&Tile> {
        self.tiles.iter().find(|t| t.x == x && t.y == y && t.z == z)
    }
    pub fn cell_protected(&self, c: Cell) -> bool {
        self.cell_protected_except(c, None)
    }
    fn cell_protected_except(&self, c: Cell, except: Option<usize>) -> bool {
        self.tiles
            .iter()
            .any(|t| t.protects_support(c) || t.occupies(c))
            || self.colonists.iter().enumerate().any(|(index, actor)| {
                if except == Some(index) {
                    return false;
                }
                let b = actor.spatial.body;
                c.0 >= actor.position.x
                    && c.0 < actor.position.x + i32::from(b.width)
                    && c.1 >= actor.position.y
                    && c.1 < actor.position.y + i32::from(b.depth)
                    && c.2 >= actor.spatial.z - 1
                    && c.2 < actor.spatial.z + i32::from(b.height)
            })
            || self
                .stacks
                .iter()
                .any(|s| s.x == c.0 && s.y == c.1 && (s.z == c.2 || s.z - 1 == c.2))
    }

    /// Facilities are capability reservations, not material walls. Complete volume
    /// overlap is prohibited but actors can visit and cross these room/work zones.
    pub fn validate_placement(&self, tile: &Tile) -> Result<(), String> {
        let g = self.geometry.as_ref().ok_or("live geometry missing")?;
        if tile.kind == TileKind::Empty || !g.supported(tile.base(), tile.body()) {
            return Err(
                "facility needs positive dimensions, full clearance and solid support".into(),
            );
        }
        for x in tile.x..tile.x + i32::from(tile.width) {
            for y in tile.y..tile.y + i32::from(tile.depth) {
                for z in tile.z..tile.z + i32::from(tile.clearance_height) {
                    if self
                        .tiles
                        .iter()
                        .any(|existing| existing.occupies(Cell(x, y, z)))
                    {
                        return Err("facility volumes overlap".into());
                    }
                }
            }
        }
        Ok(())
    }

    /// Durable IDs are allocated beyond the current maximum, never from z/grid
    /// encoding. Keeping empty operational rows means canceled jobs cannot reuse IDs.
    pub fn allocate_tile(&mut self, p: Cell, kind: TileKind) -> Result<Tile, String> {
        if let Some(t) = self.tile_at_elevation(p.0, p.1, p.2) {
            return Ok(t.clone());
        }
        let id = self
            .tiles
            .iter()
            .map(|t| t.id)
            .max()
            .unwrap_or(0)
            .checked_add(1)
            .ok_or("tile ID exhausted")?;
        let t = Tile {
            id,
            x: p.0,
            y: p.1,
            z: p.2,
            kind,
            enabled: true,
            width: 1,
            depth: 1,
            clearance_height: 4,
        };
        self.tiles.push(t.clone());
        Ok(t)
    }

    /// Returns designation index, cell index, reachable supported work position.
    pub fn mining_job(&self, index: usize) -> Option<(usize, usize, Cell)> {
        let g = self.geometry.as_ref()?;
        let body = self.colonists[index].spatial.body;
        let reachable = self.actor_reachability(index);
        let mut intents: Vec<_> = g
            .designations
            .iter()
            .enumerate()
            .filter(|(_, d)| d.enabled)
            .collect();
        intents.sort_unstable_by_key(|(_, d)| (d.priority, d.id));
        for (di, d) in intents {
            for (ci, c) in d
                .cells
                .iter()
                .enumerate()
                .filter(|(_, c)| c.material != AIR)
            {
                // Invert the work-face/footprint relation: at most a narrow
                // perimeter and ceiling range, NOT all reachable nodes per job.
                let cell = c.cell();
                let mut best = None;
                let mut consider = |p: Cell| {
                    if let Some((distance, _)) = reachable.get(&p) {
                        if g.mine_reachable(p, body, cell) {
                            let key = (distance, p);
                            if best.is_none_or(|old| key < old) {
                                best = Some(key);
                            }
                        }
                    }
                };
                let w = i32::from(body.width).min(g.width);
                let depth = i32::from(body.depth).min(g.height);
                for z in cell.2 - 5..=cell.2 + 1 {
                    for y in cell.1 - depth + 1..=cell.1 {
                        consider(Cell(cell.0 - w, y, z));
                        consider(Cell(cell.0 + 1, y, z));
                    }
                    for x in cell.0 - w + 1..=cell.0 {
                        consider(Cell(x, cell.1 - depth, z));
                        consider(Cell(x, cell.1 + 1, z));
                    }
                }
                for z in cell.2 - 5..=cell.2 - i32::from(body.height) {
                    for y in cell.1 - depth + 1..=cell.1 {
                        for x in cell.0 - w + 1..=cell.0 {
                            consider(Cell(x, y, z));
                        }
                    }
                }
                // Re-evaluate dynamic reservations on every decision; actor,
                // facility and goods protection is not cached with terrain.
                if let Some((_, p)) = best {
                    if !self.cell_protected_except(cell, Some(index)) {
                        return Some((di, ci, p));
                    }
                }
            }
        }
        None
    }

    pub(super) fn live_destination(
        &self,
        index: usize,
        tuning: &Tuning,
        goal: Goal,
    ) -> Option<Tile> {
        self.geometry.as_ref()?;
        let actor = &self.colonists[index];
        if goal == Goal::Work && actor.assignment.work == WorkType::Mining {
            let (_, _, p) = self.mining_job(index)?;
            return Some(Tile {
                id: 0,
                x: p.0,
                y: p.1,
                z: p.2,
                kind: TileKind::Mine,
                enabled: true,
                width: 1,
                depth: 1,
                clearance_height: 4,
            });
        }
        let reachable = self.actor_reachability(index);
        let kind = goal.tile_kind(actor.assignment.work, actor.is_carrying())?;
        self.tiles
            .iter()
            .filter(|t| {
                if goal == Goal::Haul
                    && !actor.is_carrying()
                    && actor.assignment.work == WorkType::Mining
                {
                    return self.stack_amount(t.id, ResourceKind::Stone) > 0.0
                        && reachable.contains_key(&t.base());
                }
                if t.kind != kind {
                    return false;
                }
                if !reachable.contains_key(&t.base()) {
                    return false;
                }
                if goal == Goal::Work {
                    return self.active_work_order(t, actor.assignment.work).is_some();
                }
                if goal == Goal::Haul && !actor.is_carrying() {
                    return self.supply_ready(t, actor.assignment.work, tuning);
                }
                t.enabled
            })
            .min_by_key(|t| {
                let priority = if goal == Goal::Work || (goal == Goal::Haul && !actor.is_carrying())
                {
                    self.active_work_order(t, actor.assignment.work)
                        .map_or(3, |o| o.priority)
                } else {
                    0
                };
                (priority, reachable.get(&t.base()).unwrap().0, t.id)
            })
            .cloned()
    }

    pub(super) fn step_live_travel(&mut self, index: usize, tuning: &Tuning, dt_hours: f32) {
        let mut steps =
            self.colonists[index].movement.progress + tuning.move_tiles_per_hour * dt_hours;
        let actor = &self.colonists[index];
        let id = actor.id;
        let target = Cell(
            actor.movement.target.x,
            actor.movement.target.y,
            actor.spatial.target_z,
        );
        let mut path = self.navigation.borrow_mut().route(
            self.geometry.as_ref().unwrap(),
            id,
            self.actor_cell(index),
            actor.spatial.body,
            target,
            actor.spatial.next,
        );
        let mut consumed = 0;
        loop {
            let start = self.actor_cell(index);
            if path.front() != Some(&start) {
                self.colonists[index].movement.progress = 0.0;
                self.colonists[index].spatial.next = start;
                return;
            }
            let next = path.get(1).copied().unwrap_or(start);
            self.colonists[index].spatial.next = next;
            if start == target {
                steps = 0.0;
                break;
            }
            if steps < 1.0 {
                break;
            }
            steps -= 1.0;
            let actor = &mut self.colonists[index];
            actor.position.x = next.0;
            actor.position.y = next.1;
            actor.spatial.z = next.2;
            path.pop_front();
            consumed += 1;
        }
        self.navigation.borrow_mut().consume_route(id, consumed);
        self.colonists[index].movement.progress = steps;
    }

    pub(super) fn step_mining(&mut self, index: usize, tuning: &Tuning, dt_hours: f32) {
        let Some((di, ci, p)) = self.mining_job(index) else {
            return;
        };
        if self.actor_cell(index) != p {
            return;
        }
        let c = self.geometry.as_ref().unwrap().designations[di].cells[ci].cell();
        if self.cell_protected(c) {
            return;
        }
        let amount = tuning.output_per_hour(ResourceKind::Stone)
            * self.colonists[index].wellbeing.productivity
            / 100.0
            * dt_hours;
        let g = self.geometry.as_mut().unwrap();
        let job = &mut g.designations[di].cells[ci];
        let progress = (job.progress + amount.max(0.0)).min(1.0);
        if job.progress != progress {
            job.progress = progress;
            g.dirty_jobs.insert(g.designations[di].id);
        }
        // One resource unit per atomic solid cell, never continuous/infinite ore.
        if progress < 1.0 {
            return;
        }
        let Ok(tile) = self.allocate_tile(p, TileKind::Empty) else {
            // ID exhaustion must not remove a cell without a durable pile anchor.
            return;
        };
        let g = self.geometry.as_mut().unwrap();
        if !g.set(c, AIR) {
            return;
        }
        g.designations[di].cells[ci].material = AIR;
        g.designations[di].cells[ci].progress = 1.0;
        g.dirty_designations.insert(g.designations[di].id);
        g.dirty_jobs.insert(g.designations[di].id);
        self.add_to_stack(&tile, ResourceKind::Stone, 1.0);
    }
}

#[cfg(test)]
mod tests;
