# agent-bus tui: goals

One screen, left open all day, for running every agent on both Macs. At a
glance you know who needs you, who is doing what, and who is idle, and you can
act without hunting for windows.

## Goals

1. **Show what needs you.** A blocked ask you can act on is impossible to
   miss: a red badge, and a macOS notification when a new one arrives. Nothing
   else gets a badge (stale asks from agents that have exited don't).
2. **Show who is doing what.** Every agent has a readable name, a one-line
   focus, and where it is: repo, ticket, branch, its own ports, which Mac.
3. **Keep the roster honest.** Agents that offboard leave the grid and come
   back only when they take new work. Idle ones dim. What's on screen is worth
   looking at.
4. **Get to the agent.** Find any agent in a keystroke (`/`), slice the grid
   the way you think (`g`), and jump to the app it runs in (double-click, or
   enter in its panel).
5. **Act from here.** Answer, close, offboard, or open its folder and ports.
6. **Show what happened.** A navigable history per agent (`c`) and for the
   whole bus (`a`).

## Non-goals

- Doing an agent's work, or editing code. The TUI only talks over the bus.
- Being the main place you chat with agents; their own windows are.
- Live streaming of what an agent is doing inside its session.
- Its own state. Every action is an `agent-bus` command you could run yourself.
