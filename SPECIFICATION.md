# LatticeTopology Window Manager for MacOS

## Zones

### Zones abstraction

A zone can either contain an (unminimized) window or be empty. There can be at most one window per zone.
Minimized windows do not belong to any zone.
Each zone has an index (for example, if there are 3 zones, then the indexes are: 1, 2, and 3).

If a new window is created or a window is unminimized:

- If there is an empty zone it should be placed there. If multiple zones are empty, preference should be given to the zone with a lower index.
- If there is no empty zone, then the new window should replace the existing window in the zone with the highest index. The old window in that zone should be minimized. (For the smoothest effect, we want to first move the new window to the right location, and only then minimize the old window.)

### Resizing windows

When a window is placed in a zone, it would be moved and resized to match the zone dimensions.
Important: When some windows are resized, they might not actually attain the dimensions requested. For example, a window might have a minimum width, etc. We should not keep on trying to resize them in an infinite loop.

### Zone visual representation

If a zone contains a window, then that window simply "represents" the zone. Note that the size of the window may not match the size of the zone. (For example, certain windows cannot be resized arbitrarily.)

Every empty zone, should have a placeholder window created by our window manager. The placeholder windows should be semi-translucent, with no text.
They should not have a title bar or any of the normal buttons (ie minimize, close, zoom).
Instead there should be a blue button with an "x" in it, looking similar to a normal close button but larger and semi-translucent.
Clicking this button should remove this zone.

### Adding and removing zones

When adding or removing zones, the remaining zones should be reindexed. For example, if there are zones 1, 2, 3, and I remove zone 1, then zone 2 should become zone 1, and zone 3 should become zone 2.

There are two ways to remove a zone:

- By pressing the blue "x" button on the placeholder window of an empty zone.
- By pressing a keyboard shortcut Control-Cmd-[minus].

The minimum number of zones is 1. In other words, we cannot remove the last zone. The maximum number of zones is 3 (for now).

There is one way to add a zone: by pressing the keyboard shortcut Control-Cmd-=. The new zone should be added with the highest index, and it should start out initially empty.
