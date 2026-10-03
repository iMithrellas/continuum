//! Pure constructed-envelope capabilities. No material walls, heat flow or spoilage.
use super::construction::{validate_cost, BlockRect, MAX_ATOMIC_BUILD_CELLS};
use super::geometry::{Body, Cell, Geometry};

pub const ROOM_WOOD_PER_CELL: f32 = 5.0;
pub const ROOM_THERMAL_RESISTANCE: f32 = 2.0;

/// Internal composition is deliberately independent of public recipe/table layout.
#[derive(Clone, Debug, PartialEq)]
pub struct RoomEnvelope {
    pub id: u64,
    pub base: Cell,
    pub width: u16,
    pub depth: u16,
    pub height: u16,
    pub thermal_resistance: Option<f32>,
}

impl RoomEnvelope {
    pub fn contains(&self, p: Cell) -> bool {
        self.width > 0
            && self.depth > 0
            && self.height > 0
            && i64::from(p.0) >= i64::from(self.base.0)
            && i64::from(p.0) < i64::from(self.base.0) + i64::from(self.width)
            && i64::from(p.1) >= i64::from(self.base.1)
            && i64::from(p.1) < i64::from(self.base.1) + i64::from(self.depth)
            && i64::from(p.2) >= i64::from(self.base.2)
            && i64::from(p.2) < i64::from(self.base.2) + i64::from(self.height)
    }

    pub fn protects_support(&self, p: Cell) -> bool {
        i64::from(p.2) + 1 == i64::from(self.base.2) && self.contains(Cell(p.0, p.1, self.base.2))
    }

    pub fn overlaps(&self, other: &Self) -> bool {
        fn interval(a: i32, aw: u16, b: i32, bw: u16) -> bool {
            aw > 0
                && bw > 0
                && i64::from(a) < i64::from(b) + i64::from(bw)
                && i64::from(b) < i64::from(a) + i64::from(aw)
        }
        interval(self.base.0, self.width, other.base.0, other.width)
            && interval(self.base.1, self.depth, other.base.1, other.depth)
            && interval(self.base.2, self.height, other.base.2, other.height)
    }
}

pub fn preflight_room(rect: BlockRect, height: u16, wood: f32) -> Result<f32, String> {
    let cells = rect.cells()?;
    if cells > MAX_ATOMIC_BUILD_CELLS {
        return Err(format!(
            "one room supports at most {MAX_ATOMIC_BUILD_CELLS} cells"
        ));
    }
    if height < 4 {
        return Err("room requires at least four clear cells".into());
    }
    let cost = cells as f32 * ROOM_WOOD_PER_CELL;
    validate_cost(wood, cost)?;
    Ok(cost)
}

/// Checks the complete volume/support; zones and actors deliberately are not inputs.
pub fn plan_room(
    geometry: &Geometry,
    existing: &[RoomEnvelope],
    rect: BlockRect,
    z: i32,
    height: u16,
    wood: f32,
) -> Result<(RoomEnvelope, f32), String> {
    let cost = preflight_room(rect, height, wood)?;
    let width = u16::try_from(i64::from(rect.max_x) - i64::from(rect.min_x) + 1)
        .map_err(|_| "room width exceeds supported dimensions")?;
    let depth = u16::try_from(i64::from(rect.max_y) - i64::from(rect.min_y) + 1)
        .map_err(|_| "room depth exceeds supported dimensions")?;
    let room = RoomEnvelope {
        id: 0,
        base: Cell(rect.min_x, rect.min_y, z),
        width,
        depth,
        height,
        thermal_resistance: Some(ROOM_THERMAL_RESISTANCE),
    };
    if !geometry.supported(
        room.base,
        Body {
            width,
            depth,
            height,
            step: 0,
        },
    ) {
        return Err("room needs full bounds, clearance and solid support".into());
    }
    if existing.iter().any(|other| room.overlaps(other)) {
        return Err("building volumes overlap".into());
    }
    Ok((room, cost))
}

impl super::World {
    pub fn room_thermal_resistance_at(&self, p: Cell) -> Option<f32> {
        self.buildings
            .iter()
            .filter(|b| b.contains(p))
            .min_by_key(|b| b.id)
            .and_then(|b| b.thermal_resistance)
    }
}

#[cfg(test)]
mod tests;
