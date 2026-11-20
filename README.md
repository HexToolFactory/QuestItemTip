# Quest Item Tip

A World of Warcraft: Forever addon that tells you in an item's tooltip which quests the item belongs to - and, once
those quests are done, asks whether the leftover quest item can go.

> # ⚠️ DISCLAIMER: PROCEDURAL DATA, NOT CURATED
> **Everything this addon shows is generated automatically.** The item-to-quest links are computed at login from the
> quest database of QuestieDB; nobody has checked them by hand, item by item.
>
> - A quest can be **missing** from an item, and an item can be listed for a quest it is **not really needed** for.
> - "Completed", "Not started" and "no longer needed" are conclusions drawn from that data, **not verified facts**.
> - The delete question is a **suggestion**. Nothing is ever deleted without your click, and a deleted quest item
>   may be impossible to get back - **when in doubt, press Keep.**

## Tooltip
Every item tooltip gets one line per quest, with the state of that quest on the right:

| Left | Right |
|---|---|
| `Needed for: [48] The Scrimshank Redemption` | `In log 2/5`, `Not started`, `From level 39` or `Completed` |
| `Starts: [10] The Collector` | same states |

Other labels: `Used for`, `Provided for` (the quest giver hands the item out with the quest) and `Related to`.

- Works for quests that are **not in your log yet**, so you can tell whether a drop is worth keeping.
- Quests of the other faction or another class are hidden by default.
- Several quests with the same name share one line; at most six lines per item (adjustable).

## Leftover quest items
About two seconds after you hand a quest in, the addon looks through your bags for items of that quest and asks
whether to delete them. It only asks when it is sure the item is finished:

- the game classes the item as a quest item (keys, reagents and gear are never offered),
- no quest rewards it,
- every quest it belongs to is completed or closed to your character,
- none of its quests is in your log, not started yet or repeatable.

**Delete** destroys one stack per click and stays open until all are gone, **Keep** never asks about that item again, **Escape** asks again
next time. The question never appears in combat.

## Requirements
**[QuestieDB](https://www.curseforge.com/wow/addons/questiedb)** - a separate addon with the quest data. The CurseForge
app installs it together with Quest Item Tip. Questie is not needed.
Without QuestieDB the tooltip only knows the objectives of quests in your log, and the delete question is never asked.

## Commands
- `/qit` - status and all commands
- `/qit on` | `off` - tooltip lines
- `/qit done` - show or hide completed quests
- `/qit other` - show or hide quests of the other faction or another class
- `/qit rewards` - show or hide "Reward from" lines
- `/qit ids` - show or hide quest IDs
- `/qit max <n>` - most lines per item
- `/qit item <id or link>` - print an item's quest lines to chat
- `/qit ask` - turn the delete question on or off
- `/qit cleanup` - check your whole bags for leftover quest items
- `/qit forget` - clear all Keep answers
- `/qit rebuild` - build the quest index again

## Install
Copy the `QuestItemTip` folder into `_forever_\Interface\AddOns`, or install it from CurseForge.

## License
MIT - see [LICENSE](LICENSE). The addon contains no quest data of its own; it reads QuestieDB at run time.
