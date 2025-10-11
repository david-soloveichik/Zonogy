# LatticeTopology Window Manager for MacOS

LatticeTopology is a variation on a tiling window manager. In particular, it uses the concept of "zones" to give the user more control over tiling, essentially allowing "reserving" space for future windows. This also is meant to overcome a major annoyance with tiling window managers in that there is too much resizing and repositioning of windows and users close and open new windows.

## Zones

### Zones abstraction

A zone can either contain an (unminimized) window or be empty. There can be at most one window per zone.
Minimized windows do not belong to any zone.
Each zone has an index (for example, if there are 3 zones, then the indexes are: 1, 2, and 3).

### Initial startup behavior

When LatticeTopology starts, it begins with 1 zone by default. All windows on the screen should be minimized for a clean start.

### Window placement for new windows

If a new window is created or a window is unminimized:

- If there is an empty zone it should be placed there. If multiple zones are empty, preference should be given to the zone with a lower index.
- If there is no empty zone, then the new window should replace the existing window in the zone with the highest index. The old window in that zone should be minimized. (For the smoothest effect, we want to first move the new window to the right location, and only then minimize the old window.)

### Repositioning and Resizing windows (analog of tiling)

When a window is placed in a zone, it would be moved and resized to match the zone dimensions.
Important: When some windows are resized, they might not actually attain the dimensions requested. For example, a window might have a minimum width, etc. We should not keep on trying to resize them in an infinite loop.

### Zone visual representation

If a zone contains a window, then that window simply "represents" the zone and there is no placeholder window. Note that the size of the window may not match the size of the zone. (For example, certain windows cannot be resized arbitrarily.)

Every empty zone, should have a placeholder window created by our window manager. The placeholder windows should be semi-translucent, with no text.
They should not have a title bar or any of the normal buttons (ie minimize, close, zoom).
Instead there should be a blue button with an "x" in it, looking similar to a normal close button but larger and semi-translucent.
Clicking this button should remove this zone.

**Usage example**: Suppose the user starts with 2 zones, zone 1 containing window A and zone 2 containing window B. To get rid of zone 1 the user can take the following actions: minimize window A, which leads to the placeholder window appearing, and then clicking on the blue "x" button on the placeholder window.

### Adding and removing zones

When adding or removing zones, the remaining zones should be reindexed. For example, if there are zones 1, 2, 3, and I remove zone 1, then zone 2 should become zone 1, and zone 3 should become zone 2.

Whenever zones are added or removed, they should be re-"tiled" to split the screen. The tiling is as follows:

- 1 zone: full screen
- 2 zones: split the screen into left and right
- 3 zones: split the screen into left and right/top, right/bottom

There are two ways to remove a zone:

- By pressing the blue "x" button on the placeholder window of an empty zone.
- By pressing a keyboard shortcut Control-Cmd-[minus].

The minimum number of zones is 1. In other words, we cannot remove the last zone. The maximum number of zones is 3 (for now).

There is one way to add a zone: by pressing the keyboard shortcut Control-Cmd-=. The new zone should be added with the highest index, and it should start out initially empty.

## Debugging

For debugging purposes, it is important to see where all the windows are, whether they are minimized or not, and obtain other information about them. This can help us debug, for example, whether the window was successfully moved to its zone location.

To list the positions and other information about windows, we should use `winmanmon`. The `--help` command line argument explains the functionality.

## External locations

Tool `winmanmon`: `/Users/dsolov/Documents/Development/VibeDevelopment/WindowManagerMonitor-claude/.build/release/winmanmon`
