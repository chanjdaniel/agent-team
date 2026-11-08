---
description: A React useEffect question, which names an effect but no Effect code, leaves the skill alone.
tags: [effect]
model: claude-opus-5-5
max_turns: 10
timeout_seconds: 600
allowed_tools: [Read, Glob, Grep, Skill]
---

In a React 19 app, my component's `useEffect` runs twice in development and fires its fetch twice. Why, and how should the effect clean up so the duplicate request does no harm? Answer in a few lines, no code changes.
