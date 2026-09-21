# XanaRings

Custom gamepad radial menus for World of Warcraft: Forever.

Build your own radial menus ("rings") filled with spells and items, put each
ring on your action bar as a macro, and pick what to use with the stick.

## Installing

1. Put the `XanaRings` folder in your Forever client's `Interface/AddOns` folder.
   The folder must be named exactly `XanaRings` and contain `XanaRings.toc`
   and `Core.lua`.
2. Start the game (or type `/reload` if it is already running).
3. If the addon list says it is out of date, tick "Load out of date AddOns".

## Quick start

1. **Create a ring:**

   ```
   /xrings new Potions
   ```

   The ring editor opens in the middle of the screen with a single "+" slot.

2. **Fill it.** Drag a spell from your spellbook or an item from your bags and
   drop it on the "+" to add it. A new "+" appears each time, so keep adding
   as many as you like; the circle grows to make room. Drop on an existing
   icon to replace it. Right-click an icon to remove it (the rest close up).
   Click Done when finished.

3. **Make its macro:**

   ```
   /xrings macro Potions
   ```

   A macro appears on your cursor. Drop it on any action bar slot.

4. **Use it.** Press that action bar button and the ring opens.

   | Input          | Action                                          |
   |----------------|-------------------------------------------------|
   | Tilt the stick | Highlight a slot                                |
   | A              | Use the highlighted spell or item               |
   | B (or Escape)  | Close the ring without using anything           |
   | D-pad          | Instantly use the slot lying in that direction  |

   Pressing the macro again while the ring is open also closes it.

You can make as many rings as you have free macro slots.

## Commands

| Command                        | Description                                                          |
|--------------------------------|----------------------------------------------------------------------|
| `/xrings new <name>`           | Create a ring and open the editor                                    |
| `/xrings edit <name>`          | Reopen the editor for an existing ring                               |
| `/xrings rename <old> > <new>` | Rename a ring, e.g. `/xrings rename Potions > Consumables`           |
| `/xrings macro <name>`         | Create (or refresh) the ring's macro and pick it up                  |
| `/xrings list`                 | Show all rings and how many entries each has                         |
| `/xrings delete <name>`        | Delete a ring **and** its macro                                      |

`/xanarings` works as a longer alias for `/xrings`.

## Tips

- The first entry is at the top and the rest run clockwise, evenly spaced.
  The D-pad uses whichever entry sits closest to up / right / down / left, so
  in a ring of 8 that is entries 1, 3, 5 and 7, and in a ring of 12 it is
  1, 4, 7 and 10. Adding or removing entries shifts which ones those are.
- Rings have no fixed size, but there is a ceiling: a ring has to fit inside
  its 255-character macro, which works out to roughly 20-30 entries depending
  on how long the spell and item IDs are. The editor tells you when a ring is
  full. In practice, more than about 12 gets fiddly to aim at with a stick;
  two smaller rings are usually nicer than one huge one.
- The highlight is "sticky": once you tilt toward a slot you can let the stick
  go and the slot stays selected until you press A.
- Renaming a ring also retitles its macro (`XR <name>`), unless you gave the
  macro your own name, in which case it is left alone. The macro stays where
  it is on your action bar either way.
- The macro icon is taken from the first entry. After changing a ring,
  run `/xrings macro <name>` again if you want the icon refreshed.
- Your character stops steering while the ring is open, because the ring
  takes over the stick. Close it with B if you opened it by accident.

## Known limitations (current Forever beta)

- **Rings do not open in combat.** The beta client is missing the function that
  compiles secure addon snippets, which is the only way an addon may change
  bindings during combat. If you enter combat with a ring open, it closes
  itself. This should become possible again once Blizzard fixes the client.

- **Always make the macro.** The beta client does not reload addon saved settings
  between sessions, so XanaRings stores each ring's contents inside its macro
  and rebuilds your rings from your macros at login. A ring that has no macro
  will be gone after you log out. `/xrings list` warns you about rings that
  have no macro yet.

- **Do not edit the second line of a ring macro** (the one starting with
  `/xrdata`). That line is the ring's saved contents. The first line,
  `/click XanaRingsOpen<number>`, is what opens the ring. You may rename the
  macro or change its icon freely.

- Deleting a ring's macro by hand does not delete the ring right away, but it
  will not come back after your next login. Use `/xrings delete` to remove a ring
  cleanly.

- Rings hold spells and items only for now. Macros, mounts and toys inside a
  ring are not supported yet.

## Troubleshooting

**Nothing happens when I press the macro**

Are you in combat? See above. Otherwise type `/xrings list` to check the
ring still exists, and make sure the addon is enabled in the AddOns list.

**"Couldn't create the macro"**

Your macro slots are full. Delete a macro you do not need and try again.

**I get a Lua error**

Type `/console scriptErrors 1` so errors show on screen, reproduce the
problem, and copy the full error text when reporting it.
