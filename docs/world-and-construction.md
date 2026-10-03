# World, rooms, and work areas

## Starting a world

New colonies begin near the centre of a 2048 × 2048-cell world. The server
prepares the world before it becomes playable and reports its actual progress
while doing so. Wait for that preparation to finish before expecting to manage
the colony. Exploring an area does not start another world-generation job.

The map may not show every label at distant zoom levels. Use the overview to
find an area, then zoom in to inspect and edit its details. The overview and
close-up views are two ways to work with the same world, not separate maps.

World preparation and later map use are different things: dividing terrain into
chunks is a way to store, send, and display it, not a promise that unexplored
areas are generated on demand. Larger worlds are an intended direction; their
performance and scale should not be taken as validated just because a large
world is specified.

Starting normally preserves the existing database. A new 2048 × 2048 world is
for a new world; it is not an automatic upgrade or regeneration of an existing
colony. Resetting a live world is a separate, explicit action and should be
treated as destructive.

## Construction and zones

Construction and Zones are separate panels. Each can be moved or collapsed
independently, so you can arrange the controls around the part of the map you
are working on.

Use Construction to create an insulated room envelope. It costs 5 wood per
cell and has a resistance of 2 m²K/W. Use Zones to designate storage or
productive work areas. A storage zone can be designated inside a room whether
you make the room first or designate the zone first.

Rooms and zones are independent. Clearing a zone does not demolish its room,
and demolishing a room does not erase a zone or refund the wood spent on the
room. Productive zones also remain distinct from work orders: the zone marks
where work may happen, while work orders express which work is wanted.

**Room caveat:** rooms are currently a traversable property abstraction. They
do not create voxel walls, control temperature, or preserve food through
spoilage effects.

## Colony permissions

Operators can build and manage colony work areas and work orders. Viewers can
inspect the colony but cannot make those changes. Admins inherit Operator
permissions and additionally control simulation speed and pause, as well as
administrative actions such as resetting the world. A visible control or panel
does not by itself grant permission to use it.
