# Changelog

## Unreleased

- A pull request whose mergeability the forge hasn't worked out by its deadline is `check stuck`, held by its author, where the reference waited on the forge indefinitely.
- A `Blocked-by:` line is invalid when it closes a loop through any waits between units, such as an issue waiting on a pull request that is blocked by the issue, not only a loop of `Blocked-by:` lines.
- A quiet obligation waits for its busy agent at most `patience` times, so an agent kept busy can no longer starve it unnoticed.
- CI re-runs are limited per head commit, counted from the forge, and spending the limit tells the human.
- Each unit has a budget of agent runs, past which the human gets one notice until they mark it seen.
- An upstream issue closed while ready for release is no longer reopened, which handed it back to the world to close again: the coordinator takes the label off instead.
- States' steps no longer name the reference's scripts, forge paths or fixed timings.
