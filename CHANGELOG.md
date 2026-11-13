# Changelog

## 0.2.0
- First public version for WoW: Forever.
- Item tooltips name the quests an item belongs to: needed for, used for, provided for, starts or related to a quest.
- Each line shows the state of that quest: in your log with progress, not started, the level it opens at, or completed.
- Knows quests that are not in your log yet (needs QuestieDB, which ships with Questie).
- Quests of the other faction or another class are hidden by default (`/qit other`).
- After you hand a quest in, asks whether to delete quest items of it that no open quest needs any more.
  Keys, reagents, gear, quest rewards and items of repeatable quests are never offered.
- `/qit cleanup` checks your whole bags for such leftovers, `/qit ask` turns the question off.
