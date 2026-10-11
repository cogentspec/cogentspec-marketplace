"""Focused tests for the state-aware GPTDesk sidebar helper."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "plugins" / "cogentspec" / "skills" / "cogentspec" / "scripts" / "ensure-codex-sidebar-hidden.py"
SPEC = importlib.util.spec_from_file_location("ensure_codex_sidebar_hidden", HELPER)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeBackend:
    def __init__(self, states: list[str], invoke_result: bool = True, verified_state: str = "hidden") -> None:
        self.states = states
        self.invoke_result = invoke_result
        self.verified_state = verified_state
        self.invocations = 0

    def find_candidates(self) -> list[object]:
        return [MODULE.SidebarCandidate(100 + index, state, index) for index, state in enumerate(self.states)]

    def invoke_hide(self, _candidate: object) -> bool:
        self.invocations += 1
        return self.invoke_result

    def read_state(self, _candidate: object) -> str:
        return self.verified_state


class SidebarStateTests(unittest.TestCase):
    def test_hidden_sidebar_is_not_toggled(self) -> None:
        backend = FakeBackend(["hidden"])
        status, details = MODULE.ensure_sidebar_hidden(backend, 0)
        self.assertEqual((status, details["processId"]), ("already_hidden", 100))
        self.assertEqual(backend.invocations, 0)

    def test_open_sidebar_is_closed_and_verified(self) -> None:
        backend = FakeBackend(["open"])
        status, _details = MODULE.ensure_sidebar_hidden(backend, 0)
        self.assertEqual(status, "hidden")
        self.assertEqual(backend.invocations, 1)

    def test_missing_sidebar_state_fails_safely(self) -> None:
        status, _details = MODULE.ensure_sidebar_hidden(FakeBackend([]), 0)
        self.assertEqual(status, "unavailable")

    def test_multiple_windows_are_not_changed(self) -> None:
        backend = FakeBackend(["open", "hidden"])
        status, details = MODULE.ensure_sidebar_hidden(backend, 0)
        self.assertEqual((status, details["candidateCount"]), ("ambiguous", 2))
        self.assertEqual(backend.invocations, 0)

    def test_failed_invoke_is_reported(self) -> None:
        status, _details = MODULE.ensure_sidebar_hidden(FakeBackend(["open"], invoke_result=False), 0)
        self.assertEqual(status, "failed")

    def test_unverified_close_is_reported(self) -> None:
        status, _details = MODULE.ensure_sidebar_hidden(FakeBackend(["open"], verified_state="open"), 0)
        self.assertEqual(status, "failed")


if __name__ == "__main__":
    unittest.main()
