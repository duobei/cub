---
name: cub
description: Delegate sub-tasks to a child cub process
---
You can delegate sub-tasks to a child cub process using `cub run '<prompt>'`.

Use this when:
- A task is independent and can be handled in isolation
- You want to parallelize work across multiple sub-agents
- The sub-task has a clear, self-contained objective

Example: `cub run 'summarize the file README.md'`

The child process inherits the current workspace and settings.
