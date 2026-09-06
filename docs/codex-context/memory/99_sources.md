# Sources used for Codex-context structure

The handoff layout intentionally follows official OpenAI guidance rather than inventing a custom memory convention without reference.

## 1. Introducing Codex — OpenAI
https://openai.com/index/introducing-codex/

Relevant guidance: repositories can use `AGENTS.md` to tell Codex how to navigate the codebase, which test commands to run, and what project practices to follow.

## 2. Unrolling the Codex agent loop — OpenAI
https://openai.com/index/unrolling-the-codex-agent-loop/

Relevant guidance: Codex aggregates `AGENTS.override.md` / `AGENTS.md` instructions from the project-root-to-cwd path, subject to an instruction-size limit (32 KiB by default), with more specific instructions later/deeper in the hierarchy.

## 3. Harness engineering: leveraging Codex in an agent-first world — OpenAI
https://openai.com/index/harness-engineering/

Relevant guidance adopted here: avoid turning one monolithic `AGENTS.md` into an encyclopedia. Keep it short and use it as a table of contents pointing to structured deeper documentation that acts as the system of record.

## 4. OpenAI Codex best-practices material
https://cdn.openai.com/pdf/5017b110-d40f-437b-94d6-ef30645d5b63/OpenAI-%E3%81%AB%E3%81%8A%E3%81%91%E3%82%8B-Codex-%E6%B4%BB%E7%94%A8%E6%96%B9%E6%B3%95.pdf

Relevant guidance: use `AGENTS.md` for persistent context including naming conventions, business logic, known caveats, and dependencies Codex cannot infer from code alone.

## Why this bundle uses `memory/`
OpenAI's guidance does not require a directory literally named `memory/`. The user requested that name. This bundle applies the documented pattern—short root instructions + structured deeper knowledge—using `memory/` as the requested knowledge-base directory.
