# Opencode Resume Capability Measurement

**Measured:** 2026-09-01 (task 6 execution)

**Finding:** `opencode` is not installed on either the local development machine or the butler (Mac mini) hub. Therefore, headless thread resume capability cannot be measured.

**Measurement command attempted:**
```bash
opencode run --help 2>&1 | grep -iA2 resume
```

**Result:** Command not found on both:
- Local machine: opencode not found in PATH
- Butler (mac mini): opencode not found in PATH

**Consequence:** The job-run.sh wrapper continues to refuse RUNTIME=opencode with explicit error message referencing this document, until a full attempt-2 integration test can be performed after opencode is installed and measured.

The refusal ensures we do not implement partial support that would silently re-run attempt 1's work via a fresh thread on attempt 2 — violating the branch-as-checkpoint contract [A2].
