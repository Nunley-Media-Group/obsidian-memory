# File: tests/features/vault-distill-async.feature
#
# Generated from: specs/bug-detach-claude-p-in-vault-distill-for-clear-async/requirements.md
# Issue: #25

@regression
Feature: Detach claude -p in vault-distill.sh for async /clear distillation
  As a Claude Code + Obsidian user who uses /clear to reset context in long sessions
  I want distillation notes to land in my vault even when /clear tears down the session quickly
  So that my vault accumulates memory across every context reset, not just on /exit

  Background:
    Given a scratch HOME at "$BATS_TEST_TMPDIR/home"
    And a scratch Obsidian vault at "$BATS_TEST_TMPDIR/vault"
    And obsidian-memory is installed and setup against "$VAULT"
    And a stub "claude" CLI is on PATH returning a fixed distillation by default

  # --- AC1: /clear triggers a distillation note ---

  @regression
  Scenario: /clear fires the hook, hook returns fast, note lands asynchronously
    Given a transcript at "$HOME/.claude/projects/my-proj/<sid>.jsonl" of size 5000 bytes
    And the stub "claude" CLI sleeps for 15 seconds before responding
    When a SessionEnd payload with reason "clear" is piped into "scripts/vault-distill.sh"
    Then "scripts/vault-distill.sh" returns within 2 seconds
    And within 30 seconds a file matching "<vault>/claude-memory/sessions/*/<YYYY-MM-DD-HHMMSS>.md" exists
    And that file contains the distilled body from the stub
    And "<vault>/claude-memory/Index.md" contains a link to the new note

  # --- AC2: Normal exit path is not regressed ---

  @regression
  Scenario: /exit produces exactly one note (no regression)
    Given a transcript at "$HOME/.claude/projects/my-proj/<sid>.jsonl" of size 5000 bytes
    When a SessionEnd payload with reason "other" is piped into "scripts/vault-distill.sh"
    Then within 30 seconds exactly one file matching "<vault>/claude-memory/sessions/*/<YYYY-MM-DD-HHMMSS>.md" exists
    And "<vault>/claude-memory/Index.md" contains exactly one link to that note

  # --- AC3: Manual distill-session skill is unaffected ---

  @regression
  Scenario: Manual distill-session pipes a synthetic payload and waits for the worker
    Given a transcript at "$HOME/.claude/projects/my-proj/<sid>.jsonl" of size 5000 bytes
    When "/obsidian-memory:distill-session" is invoked against the newest transcript
    Then within 60 seconds exactly one file matching "<vault>/claude-memory/sessions/*/<YYYY-MM-DD-HHMMSS>.md" exists
    And the skill reports the file path it wrote
    And "<vault>/claude-memory/Index.md" contains exactly one link to that note

  # --- Supporting invariants ---

  @regression
  Scenario: Trivial sessions are still skipped synchronously (no worker spawn)
    Given a transcript at "$HOME/.claude/projects/my-proj/<sid>.jsonl" of size 500 bytes
    When a SessionEnd payload with reason "clear" is piped into "scripts/vault-distill.sh"
    Then "scripts/vault-distill.sh" returns within 1 second
    And no file matches "<vault>/claude-memory/sessions/*/*.md" after 10 seconds
    And "<vault>/claude-memory/Index.md" does not exist or contains no new link

  @regression
  Scenario: Recursive claude -p SessionEnd re-entry does not write a duplicate note
    Given a transcript at "$HOME/.claude/projects/my-proj/<sid>.jsonl" of size 5000 bytes
    And the stub "claude" CLI will, upon completion, trigger a recursive SessionEnd invocation of "scripts/vault-distill.sh"
    When a SessionEnd payload with reason "clear" is piped into "scripts/vault-distill.sh"
    Then within 30 seconds exactly one file matching "<vault>/claude-memory/sessions/*/<YYYY-MM-DD-HHMMSS>.md" exists
    And "<vault>/claude-memory/Index.md" contains exactly one link to that note
