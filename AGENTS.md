# Repository Guidance

- This repository contains personal Lua programs for the CC: Tweaked Minecraft mod; programs can only be run in a CC: Tweaked computer or turtle, not as a conventional host application.
- There is no package manager, build system, formatter, test suite, CI workflow, or checked-in Lua tooling. Do not invent repository commands; validation is runtime testing in CC: Tweaked unless a tool is added explicitly. Do not include any external dependencies, they will not be available in CC: Tweaked.
- `cc_docs/` is ignored local CC: Tweaked reference documentation and is not repository source; do not modify or add it to commits. But do reference it when you need CC: Tweaked documentation.
- Before implementing or modifying a system, read that system's `readme.md` design reference and follow its documented decisions.
