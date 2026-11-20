# Changelog

## 0.2.2
- QuestieDB is now a required dependency on CurseForge. The CurseForge app installs it with Quest Item Tip.
  QuestieDB is a separate addon; it does not come with Questie, and Questie is not needed.
- The addon itself is unchanged and still runs without QuestieDB, with less: only quests in your log, no delete question.

## 0.2.1
- Fix: the Delete button tried to destroy every stack of a leftover quest item in one click. The game allows one
  delete per click and blocked the rest. Delete now destroys one stack per click and stays open, counting down,
  until all are gone.

## 0.2.0
- First public version for WoW: Forever.
- Item tooltips name the quests an item belongs to: needed for, used for, provided for, starts or related to a quest.
- Each line shows the state of that quest: in your log with progress, not started, the level it opens at, or completed.
- Knows quests that are not in your log yet (needs QuestieDB, which ships with Questie).
- Quests of the other faction or another class are hidden by default (`/qit other`).
- After you hand a quest in, asks whether to delete quest items of it that no open quest needs any more.
  Keys, reagents, gear, quest rewards and items of repeatable quests are never offered.
- `/qit cleanup` checks your whole bags for such leftovers, `/qit ask` turns the question off.
