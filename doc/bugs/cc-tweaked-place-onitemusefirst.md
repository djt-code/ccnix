<!-- Draft of a report for CC: Tweaked (github.com/cc-tweaked/CC-Tweaked). Not filed, for now (the owner's call, 2026-11-27). Tracked here as ccnix #392. Until CC: Tweaked fixes it: ccnix-mod's TurtlePlaceResultMixin fixes it at the source, and turtlelib's wrapped place goes by the item count, so the Lua is right on a patched CC or an unpatched one. -->

# `turtle.place()` returns false after placing an item that places itself in `onItemUseFirst` (NeoForge)

## Summary

On NeoForge, when the selected item does its placement in `IItemExtension.onItemUseFirst` (AE2 facades, for
example), `turtle.place()` places the item, then returns `false, "Cannot place item here"`. It often uses a
second item too, because the turtle goes on to try its other placement positions.

The cause is in `PlatformHelperImpl.useOn`. When `onItemUseFirst` returns something other than `PASS`, it
returns the event's cancellation result instead of the item's result. For an event that wasn't cancelled,
that is `PASS`.

## Versions

- Minecraft 1.21.1, NeoForge 21.1.256
- CC: Tweaked 1.120.2 (`cc-tweaked-1.21.1-forge-1.120.2.jar`)
- Applied Energistics 2 19.2.18 (used to reproduce it)

The same code is on `mc-1.21.x` (at `d81f7c8`) and `mc-1.20.x`.

## Steps to reproduce

1. Place an AE2 cable (any kind) one block in front of a turtle, with nothing else around it.
2. Put a cable facade (any block's) in the turtle's selected slot.
3. Run:

   ```lua
   local before = turtle.getItemCount()
   print(turtle.place())
   print("used", before - turtle.getItemCount())
   ```

## Expected

`true`. One facade is used, and it is on the cable's face toward the turtle.

## Actual

```
false   Cannot place item here
used    1
```

The facade is on the cable, as expected, but the call reports failure.

When AE2 cable buses sit in the other places the turtle tries (the block beyond the target, or the block
below it), a second facade is placed on one of them, and `used` is 2. In a column of cable buses with
storage buses behind a wall, 19 places used 32 facades. Every call returned false.

## Cause

`projects/forge/src/main/java/dan200/computercraft/shared/platform/PlatformHelperImpl.java`, `useOn`
([v1.21.1-1.120.2, lines 228 to 240](https://github.com/cc-tweaked/CC-Tweaked/blob/v1.21.1-1.120.2/projects/forge/src/main/java/dan200/computercraft/shared/platform/PlatformHelperImpl.java#L228-L240);
lines 247 to 248 on `mc-1.21.x`):

```java
var event = CommonHooks.onRightClickBlock(player, InteractionHand.MAIN_HAND, pos, hit);
if (event.isCanceled()) return new UseOnResult.Handled(event.getCancellationResult());

var context = new UseOnContext(player, InteractionHand.MAIN_HAND, hit);
if (!event.getUseItem().isFalse()) {
    var result = stack.onItemUseFirst(context);
    if (result != InteractionResult.PASS) return new UseOnResult.Handled(event.getCancellationResult());
}
```

The second `Handled` passes on `event.getCancellationResult()`, not `result`. The event here was not
cancelled, so its cancellation result is NeoForge's default, `InteractionResult.PASS` (see
`PlayerInteractEvent.RightClickBlock`).

What happens next, in `TurtlePlaceCommand`:

1. `doDeployOnBlock` gets `Handled(PASS)`. It checks `if (handled.result() != InteractionResult.PASS) return
   handled.result();`, so it falls through and returns `PASS`.
2. `deployOnBlock` computes `placed = ...consumesAction()`, which is false, so it reports "not placed".
3. `deploy` tries its next positions: the block one beyond, the block below, then the turtle itself. Each one
   calls `onItemUseFirst` again, which can place another item.
4. When all of them report "not placed", the command fails with "Cannot place item here".

On the AE2 side, `appeng.items.parts.FacadeItem.onItemUseFirst` (19.2.18) places the facade part, shrinks the
stack for a non-creative player, and returns `InteractionResult.sidedSuccess(level.isClientSide)`, which is
`CONSUME` on the server. So the item's result was right; it was lost on the way out of `useOn`.

## Suggested fix

Pass on the item's own result:

```diff
             var result = stack.onItemUseFirst(context);
-            if (result != InteractionResult.PASS) return new UseOnResult.Handled(event.getCancellationResult());
+            if (result != InteractionResult.PASS) return new UseOnResult.Handled(result);
```

The cancelled-event branch above it is right as it stands. The Fabric platform helper has no
`onItemUseFirst`, so it isn't affected.

## Workaround for scripts

Until it's fixed, compare the selected slot's count before and after `turtle.place()`. If the count dropped,
treat the place as done even though it returned false. Expect that one call may use two items.
