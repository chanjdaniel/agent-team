---
description: A builder asked to add an Effect v4 service fires the skill, and writes it with GA names.
tags: [effect]
model: claude-opus-5-5
max_turns: 15
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

Add an Effect v4 service, `UserRepo`, with a `findById(id: string)` method that fails with a tagged `UserNotFound` error when no user has that id, and the layer that provides it from an in-memory map.
Show the code for `src/UserRepo.ts` in your reply; change no files.
