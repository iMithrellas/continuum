# World, rooms, and work areas

## Starting a world

Fresh worlds target 2048 × 2048 cells, with the starter colony near the centre.
The server prepares the full world before it becomes playable. During that
time, the client reports the server's current phase and progress; it is not a
local estimate or an exploration-triggered spinner. Wait for server preparation
to finish before expecting to manage the colony. Exploring an area does not
start another world-generation job. Disconnecting leaves the client session but
does not cancel generation on the server.

The map hides some labels at distant zoom levels to keep the overview readable.
Click an area in the overview, then zoom in to inspect or edit its details. The
overview and close-up views are two ways to work with the same world, not
separate maps.

World preparation and later map use are different things: dividing terrain into
chunks is a way to store, send, and display it, not a promise that unexplored
areas are generated on demand. Larger worlds are an intended direction; their
performance and scale should not be taken as validated just because a large
world is specified.

This development release may replace an older colony with a fresh
2048 × 2048 world. Backward compatibility or migration of old saves is not
promised; keep a separate copy of colony data you need before changing builds.
After the new world is ready, ordinary restarts preserve it and do not
regenerate it. A live-world reset is a separate, explicit destructive action,
not part of each startup.

## Construction and zones

Construction and Zones are separate panels. Each can be moved or collapsed
independently. Drag an unpinned panel header to move it; pinning locks its
position and size. Collapse a panel to leave its header visible. Restoring a
panel keeps it within the available window bounds. F4 opens Zones and F11 opens
Construction; existing F1–F10 panel shortcuts remain unchanged.

Saved panel layouts keep their existing choices and placements when Construction
is added. In a layout that has no saved Construction entry, that panel starts
closed. Panel placement is kept within the visible window when restored.

Use Construction to create an insulated room envelope. It costs 5 wood per
cell and records thermal resistance of 2 m²K/W as metadata for possible future
thermal behavior. It does not currently change temperature or food spoilage.
Use Zones to designate storage or productive work areas; zone usage is free. A
storage zone can be designated inside a room whether you make the room first or
designate the zone first.

Rooms and zones are independent. Clearing a zone does not demolish its room,
and demolishing a room does not erase a zone or refund the wood spent on the
room. Productive zones also remain distinct from work orders: the zone marks
where work may happen, while work orders express which work is wanted.

**Room caveat:** rooms are currently a traversable property abstraction. They
do not create voxel walls or affect temperature or food spoilage. Larger
production worlds are a future direction; performance at that scale is not
established by the 2048-cell initial target.

## Colony permissions

Operators can build and manage colony work areas and work orders. Viewers can
inspect the colony but cannot make those changes. Admins inherit Operator
permissions and additionally control simulation speed and pause, as well as
administrative actions such as resetting the world. A visible control or panel
does not by itself grant permission to use it.
