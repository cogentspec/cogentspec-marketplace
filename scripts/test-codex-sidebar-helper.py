"""Focused tests for the state-aware GPTDesk sidebar helper."""

from __future__ import annotations

import importlib.util
import pathlib
import ctypes
import json
import subprocess
import sys
import unittest
from unittest.mock import patch


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True  # Never add bytecode files to an installer's package allowlist.
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


class FakeLayoutBackend(FakeBackend):
    def __init__(self, state: str = "full", *, layout_invoke: bool = True,
                 after_layout: str = "split", sidebar_after_layout: str = "hidden", **kwargs: object) -> None:
        super().__init__(**({"states": ["hidden"]} | kwargs))
        self.layout = state
        self.layout_invoke = layout_invoke
        self.after_layout = after_layout
        self.sidebar_after_layout = sidebar_after_layout
        self.layout_actions: list[str] = []

    def read_layout(self, _candidate: object) -> tuple[str, str | None]:
        return self.layout, {"full": "Enter split view", "hidden_tabs": "Show tabs"}.get(self.layout)

    def invoke_layout(self, _candidate: object, action: str) -> bool:
        self.layout_actions.append(action)
        if self.layout_invoke:
            self.layout = self.after_layout
            self.verified_state = self.sidebar_after_layout
        return self.layout_invoke


class DeskLayoutTests(unittest.TestCase):
    def test_full_view_enters_split_once(self) -> None:
        backend = FakeLayoutBackend(states=["open"])
        status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "layout_verified")
        self.assertTrue(details["layoutVerified"])
        self.assertEqual(backend.layout_actions, ["Enter split view"])
        self.assertEqual(backend.invocations, 1)

    def test_hidden_tabs_show_once(self) -> None:
        backend = FakeLayoutBackend("hidden_tabs")
        status, _ = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "layout_verified")
        self.assertEqual(backend.layout_actions, ["Show tabs"])

    def test_correct_layout_is_not_toggled(self) -> None:
        backend = FakeLayoutBackend("split")
        status, _ = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "layout_verified")
        self.assertEqual(backend.invocations, 0)
        self.assertEqual(backend.layout_actions, [])

    def test_unknown_layout_sends_no_action(self) -> None:
        backend = FakeLayoutBackend("unknown")
        with patch.object(MODULE.time, "sleep"), patch.object(MODULE.time, "monotonic", side_effect=[0, 0, 1]):
            status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "unavailable")
        self.assertFalse(details["layoutVerified"])
        self.assertEqual(backend.layout_actions, [])

    def test_failed_sidebar_does_not_change_layout(self) -> None:
        backend = FakeLayoutBackend(states=["open"], invoke_result=False)
        status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "failed")
        self.assertFalse(details["layoutVerified"])
        self.assertEqual(backend.layout_actions, [])

    def test_multiple_windows_do_not_change_layout(self) -> None:
        backend = FakeLayoutBackend(states=["open", "hidden"])
        status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "ambiguous")
        self.assertFalse(details["layoutVerified"])
        self.assertEqual(backend.layout_actions, [])
        self.assertEqual(backend.invocations, 0)

    def test_layout_action_failure_is_not_success(self) -> None:
        backend = FakeLayoutBackend(layout_invoke=False)
        status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "failed")
        self.assertFalse(details["layoutVerified"])
        self.assertEqual(backend.layout_actions, ["Enter split view"])

    def test_accepted_action_without_state_change_is_not_success(self) -> None:
        backend = FakeLayoutBackend(after_layout="full")
        status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "failed")
        self.assertFalse(details["layoutVerified"])
        self.assertEqual(backend.layout_actions, ["Enter split view"])

    def test_sidebar_reopened_during_layout_change_is_not_success(self) -> None:
        backend = FakeLayoutBackend(sidebar_after_layout="open")
        status, details = MODULE.ensure_desk_layout(backend, 0)
        self.assertEqual(status, "failed")
        self.assertFalse(details["layoutVerified"])

    def test_observed_host_layout_labels(self) -> None:
        for names, expected in [
            ({"Enter split view", "Exit full view"}, ("full", "Enter split view")),
            ({"Exit full view"}, ("full", "Exit full view")),
            ({"Show tabs", "Enter full view"}, ("hidden_tabs", "Show tabs")),
            ({"Hide tabs", "Enter full view"}, ("split", None)),
            ({"Enter full view"}, ("split", None)),
            ({"Enter full view", "New tab"}, ("split", None)),
            ({"New tab", "New tab in full view"}, ("unknown", None)),
            ({"Enter split view", "Show tabs"}, ("unknown", None)),
            (set(), ("unknown", None)),
        ]:
            with self.subTest(names=names):
                self.assertEqual(MODULE.layout_state_from_controls(names), expected)

    def test_popout_web_and_missing_destination_rejected_before_ui(self) -> None:
        for destination in [[], ["--experience", "popout"], ["--experience", "web"]]:
            process = subprocess.run([sys.executable, str(HELPER), "--ensure-split", *destination],
                                     capture_output=True, text=True, check=False)
            self.assertEqual(process.returncode, 4)
            result = json.loads(process.stdout)
            self.assertFalse(result["layoutVerified"])
            self.assertIn("desktop-ui", result["message"])

    def test_other_mode_skills_do_not_call_desk_layout_helper(self) -> None:
        for package, core in [("cogentspec", "cogentspec"), ("cogentstack", "cogentstack")]:
            for mode in ["gptpop", "gptweb", core]:
                source = (ROOT / "plugins" / package / "skills" / mode / "SKILL.md").read_text()
                self.assertNotIn("--ensure-split", source)
                self.assertNotIn("ensure-codex-sidebar-hidden.py", source)

    def test_popout_and_web_reject_sidebar_only_action_too(self) -> None:
        for mode in ["popout", "web"]:
            process = subprocess.run([sys.executable, str(HELPER), "--experience", mode],
                                     capture_output=True, text=True, check=False)
            self.assertEqual(process.returncode, 4)
            self.assertFalse(json.loads(process.stdout)["layoutVerified"])


@unittest.skipUnless(sys.platform == "win32", "Windows ctypes backend tests")
class WindowsControlTests(unittest.TestCase):
    """Exercise native adapter code with mocked COM calls, never a live window."""

    def backend(self) -> object:
        backend = object.__new__(MODULE.WindowsUiaBackend)
        backend._roots = {10: ctypes.c_void_p(11)}
        return backend

    def test_variant_has_correct_windows_abi_size(self) -> None:
        self.assertEqual(ctypes.sizeof(MODULE.VARIANT), 24 if ctypes.sizeof(ctypes.c_void_p) == 8 else 16)

    def find_control(self, offscreen: list[bool | None]) -> object:
        backend = self.backend()
        backend.automation = ctypes.c_void_p(20)

        def method(pointer: object, slot: int, *_types: object) -> object:
            def call(*args: object) -> int:
                target = args[-1]
                if pointer.value == 20 and slot == 23:
                    ctypes.cast(target, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.c_void_p(21)
                elif pointer.value == 11 and slot == 6:
                    ctypes.cast(target, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.c_void_p(22)
                elif pointer.value == 22 and slot == 3:
                    ctypes.cast(target, ctypes.POINTER(ctypes.c_int))[0] = len(offscreen)
                elif pointer.value == 22 and slot == 4:
                    ctypes.cast(target, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.c_void_p(30 + args[1])
                elif pointer.value >= 30 and slot == 21:
                    ctypes.cast(target, ctypes.POINTER(ctypes.c_int))[0] = 50000
                else:
                    raise AssertionError((pointer.value, slot))
                return 0
            return call

        with patch.object(MODULE, "com_method", side_effect=method), \
                patch.object(backend, "_bool_property", side_effect=lambda element, _: offscreen[element.value - 30]), \
                patch.object(MODULE, "release"):
            return backend._named_element(backend._roots[10], "Hide sidebar")

    def test_duplicate_controls_are_not_selected(self) -> None:
        self.assertIsNone(self.find_control([False, False]))

    def test_offscreen_and_unreadable_controls_are_not_selected(self) -> None:
        self.assertIsNone(self.find_control([True, None]))

    def test_one_visible_control_ignores_hidden_duplicate(self) -> None:
        self.assertEqual(self.find_control([True, False]).value, 31)

    def test_invokes_specific_pattern_without_foreground_shortcut(self) -> None:
        backend = self.backend()
        calls = []

        def method(_pointer: object, slot: int, *_types: object) -> object:
            calls.append(slot)
            if slot == 14:
                def get_pattern(_control: object, pattern_id: int, _iid: object, pointer: object) -> int:
                    self.assertEqual(pattern_id, 10000)
                    ctypes.cast(pointer, ctypes.POINTER(ctypes.c_void_p))[0] = ctypes.c_void_p(12)
                    return 0
                return get_pattern
            self.assertEqual(slot, 3)
            return lambda _pattern: 0

        with patch.object(backend, "_named_element", return_value=ctypes.c_void_p(13)), \
                patch.object(backend, "_bool_property", return_value=True), \
                patch.object(MODULE, "com_method", side_effect=method), patch.object(MODULE, "release"):
            self.assertTrue(backend.invoke_named(MODULE.SidebarCandidate(1, "open", 10), "Hide sidebar"))
        self.assertEqual(calls, [14, 3])

    def test_disabled_control_is_not_invoked(self) -> None:
        backend = self.backend()
        with patch.object(backend, "_named_element", return_value=ctypes.c_void_p(13)), \
                patch.object(backend, "_bool_property", return_value=False), \
                patch.object(MODULE, "com_method") as method, patch.object(MODULE, "release"):
            self.assertFalse(backend.invoke_named(MODULE.SidebarCandidate(1, "open", 10), "Hide sidebar"))
            method.assert_not_called()

    def test_unsupported_invoke_pattern_fails_without_retry(self) -> None:
        backend = self.backend()
        with patch.object(backend, "_named_element", return_value=ctypes.c_void_p(13)), \
                patch.object(backend, "_bool_property", return_value=True), \
                patch.object(MODULE, "com_method", return_value=lambda *_: -1) as method, patch.object(MODULE, "release"):
            self.assertFalse(backend.invoke_named(MODULE.SidebarCandidate(1, "open", 10), "Hide sidebar"))
            method.assert_called_once()

    def test_sidebar_state_rechecked_before_action(self) -> None:
        backend = self.backend()
        with patch.object(backend, "read_state", return_value="hidden"), patch.object(backend, "invoke_named") as invoke:
            self.assertFalse(backend.invoke_hide(MODULE.SidebarCandidate(1, "open", 10)))
            invoke.assert_not_called()

    def test_layout_state_rechecked_before_action(self) -> None:
        backend = self.backend()
        with patch.object(backend, "read_layout", return_value=("split", None)), patch.object(backend, "invoke_named") as invoke:
            self.assertFalse(backend.invoke_layout(MODULE.SidebarCandidate(1, "hidden", 10), "Enter split view"))
            invoke.assert_not_called()


if __name__ == "__main__":
    unittest.main()
