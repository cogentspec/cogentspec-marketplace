"""Repair GPTDesk host layout through explicit accessibility controls only."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import time
from ctypes import wintypes
from dataclasses import dataclass


EXIT_CODES = {
    "hidden": 0,
    "already_hidden": 0,
    "unavailable": 2,
    "ambiguous": 3,
    "failed": 4,
    "layout_verified": 0,
}


def emit(status: str, **details: object) -> int:
    print(json.dumps({"status": status, **details}, separators=(",", ":")))
    return EXIT_CODES[status]


@dataclass
class SidebarCandidate:
    process_id: int
    state: str
    token: object


def layout_state_from_controls(names: set[str]) -> tuple[str, str | None]:
    """Host labels from view-control-labels; conflicting observations fail closed."""
    full = bool(names & {"Enter split view", "Exit full view"})
    hidden = "Show tabs" in names
    if full and hidden:
        return "unknown", None
    if full:
        return "full", "Enter split view" if "Enter split view" in names else "Exit full view"
    if hidden:
        return "hidden_tabs", "Show tabs"
    if "New tab in full view" in names:
        return "unknown", None
    if names & {"Hide tabs", "Enter full view"}:
        return "split", None
    return "unknown", None


def ensure_desk_layout(backend: object, timeout_ms: int) -> tuple[str, dict[str, object]]:
    """After the one native open, repair one uniquely identified Desk window."""
    status, details = ensure_sidebar_hidden(backend, timeout_ms)
    if status not in {"hidden", "already_hidden"}:
        return status, {**details, "layoutVerified": False, "sidebarStatus": status}
    candidate = backend.selected_candidate
    deadline = time.monotonic() + max(0.5, timeout_ms / 1000)
    state, action = backend.read_layout(candidate)
    while state == "unknown" and time.monotonic() < deadline:
        time.sleep(0.1)
        state, action = backend.read_layout(candidate)
    if state == "unknown":
        return "unavailable", {**details, "layoutVerified": False, "sidebarStatus": status,
                               "message": "The host workspace layout could not be identified; no layout action was sent."}
    if state != "split":
        if not backend.invoke_layout(candidate, action):
            return "failed", {**details, "layoutVerified": False, "sidebarStatus": status,
                              "message": "The explicit split-view control could not be invoked."}
        deadline = time.monotonic() + max(0.5, timeout_ms / 1000)
        while time.monotonic() < deadline:
            time.sleep(0.1)
            state, _action = backend.read_layout(candidate)
            if state == "split":
                break
    # Recheck BOTH states after the final action; acceptance alone is not proof.
    state, _action = backend.read_layout(candidate)
    sidebar = backend.read_state(candidate)
    if state == "split" and sidebar == "hidden":
        return "layout_verified", {**details, "layoutVerified": True,
                                   "sidebarStatus": status, "sidebarState": sidebar, "workspaceLayout": state}
    return "failed", {**details, "layoutVerified": False, "sidebarStatus": status,
                      "sidebarState": sidebar, "workspaceLayout": state,
                      "message": "The host did not verify split view with the sidebar hidden after the action."}


def ensure_sidebar_hidden(backend: object, timeout_ms: int) -> tuple[str, dict[str, object]]:
    deadline = time.monotonic() + (timeout_ms / 1000)
    candidates: list[SidebarCandidate] = []
    while True:
        candidates = backend.find_candidates()
        if len(candidates) == 1:
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(0.1)

    if not candidates:
        return "unavailable", {"message": "No accessible Codex window with an explicit sidebar state was found."}
    if len(candidates) > 1:
        return "ambiguous", {
            "message": "More than one accessible Codex window exposes a sidebar state.",
            "candidateCount": len(candidates),
        }

    candidate = candidates[0]
    backend.selected_candidate = candidate
    if candidate.state == "hidden":
        return "already_hidden", {"processId": candidate.process_id}
    if candidate.state != "open" or not backend.invoke_hide(candidate):
        return "failed", {
            "message": "The open Codex sidebar could not be closed through its accessibility control.",
            "processId": candidate.process_id,
        }

    verify_deadline = time.monotonic() + max(0.5, timeout_ms / 1000)
    while time.monotonic() < verify_deadline:
        time.sleep(0.1)
        if backend.read_state(candidate) == "hidden":
            return "hidden", {"processId": candidate.process_id}
    return "failed", {
        "message": "The Codex sidebar did not report a closed state after the close action.",
        "processId": candidate.process_id,
    }


if os.name == "nt":
    HRESULT = ctypes.c_long
    UIA_NAME_PROPERTY_ID = 30005
    UIA_BUTTON_CONTROL_TYPE_ID = 50000
    UIA_IS_ENABLED_PROPERTY_ID = 30010
    UIA_IS_OFFSCREEN_PROPERTY_ID = 30022
    UIA_INVOKE_PATTERN_ID = 10000
    TREE_SCOPE_DESCENDANTS = 0x4
    CLSCTX_INPROC_SERVER = 0x1
    COINIT_APARTMENTTHREADED = 0x2
    RPC_E_CHANGED_MODE = -2147417850
    VT_BSTR = 8
    VT_BOOL = 11
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

    class GUID(ctypes.Structure):
        _fields_ = [
            ("Data1", wintypes.DWORD),
            ("Data2", wintypes.WORD),
            ("Data3", wintypes.WORD),
            ("Data4", ctypes.c_ubyte * 8),
        ]

        @classmethod
        def parse(cls, value: str) -> "GUID":
            import uuid

            parsed = uuid.UUID(value)
            raw = parsed.bytes_le
            return cls.from_buffer_copy(raw)

    class VARIANT_RECORD(ctypes.Structure):
        _fields_ = [("pvRecord", ctypes.c_void_p), ("pRecInfo", ctypes.c_void_p)]

    class VARIANT_VALUE(ctypes.Union):
        _fields_ = [
            ("llVal", ctypes.c_longlong),
            ("lVal", ctypes.c_long),
            ("bstrVal", ctypes.c_void_p),
            ("punkVal", ctypes.c_void_p),
            ("boolVal", ctypes.c_short),
            ("record", VARIANT_RECORD),
        ]

    class VARIANT(ctypes.Structure):
        _anonymous_ = ("value",)
        _fields_ = [
            ("vt", wintypes.WORD),
            ("wReserved1", wintypes.WORD),
            ("wReserved2", wintypes.WORD),
            ("wReserved3", wintypes.WORD),
            ("value", VARIANT_VALUE),
        ]

    CLSID_CUIAUTOMATION = GUID.parse("ff48dba4-60ef-4201-aa87-54103eef594e")
    IID_IUIAUTOMATION = GUID.parse("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")
    IID_IUIAUTOMATION_INVOKE_PATTERN = GUID.parse("fb377fbe-8ea6-46d5-9c73-6499642d3059")

    ole32 = ctypes.OleDLL("ole32")
    oleaut32 = ctypes.WinDLL("oleaut32")
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    ole32.CoInitializeEx.argtypes = [ctypes.c_void_p, wintypes.DWORD]
    ole32.CoInitializeEx.restype = HRESULT
    ole32.CoUninitialize.argtypes = []
    ole32.CoCreateInstance.argtypes = [
        ctypes.POINTER(GUID),
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(GUID),
        ctypes.POINTER(ctypes.c_void_p),
    ]
    ole32.CoCreateInstance.restype = HRESULT
    oleaut32.SysAllocString.argtypes = [wintypes.LPCWSTR]
    oleaut32.SysAllocString.restype = ctypes.c_void_p
    oleaut32.SysFreeString.argtypes = [ctypes.c_void_p]
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel32.QueryFullProcessImageNameW.restype = wintypes.BOOL
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD

    def succeeded(result: int) -> bool:
        return result >= 0

    def com_method(pointer: ctypes.c_void_p, index: int, *argtypes: object) -> object:
        vtable = ctypes.cast(pointer, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
        return ctypes.WINFUNCTYPE(HRESULT, ctypes.c_void_p, *argtypes)(vtable[index])

    def release(pointer: ctypes.c_void_p | None) -> None:
        if pointer and pointer.value:
            com_method(pointer, 2)(pointer)

    class WindowsUiaBackend:
        def __init__(self) -> None:
            result = ole32.CoInitializeEx(None, COINIT_APARTMENTTHREADED)
            self._uninitialize = succeeded(result)
            if not self._uninitialize and result != RPC_E_CHANGED_MODE:
                raise OSError(f"COM initialization failed: 0x{result & 0xFFFFFFFF:08X}")
            self.automation = ctypes.c_void_p()
            result = ole32.CoCreateInstance(
                ctypes.byref(CLSID_CUIAUTOMATION),
                None,
                CLSCTX_INPROC_SERVER,
                ctypes.byref(IID_IUIAUTOMATION),
                ctypes.byref(self.automation),
            )
            if not succeeded(result):
                raise OSError(f"Windows UI Automation initialization failed: 0x{result & 0xFFFFFFFF:08X}")
            self._roots: dict[int, ctypes.c_void_p] = {}

        def close(self) -> None:
            for root in self._roots.values():
                release(root)
            self._roots.clear()
            release(self.automation)
            if self._uninitialize:
                ole32.CoUninitialize()

        @staticmethod
        def _bool_property(element: ctypes.c_void_p, property_id: int) -> bool | None:
            value = VARIANT()
            get_value = com_method(element, 10, ctypes.c_int, ctypes.POINTER(VARIANT))
            result = get_value(element, property_id, ctypes.byref(value))
            return bool(value.boolVal) if succeeded(result) and value.vt == VT_BOOL else None

        def _named_element(self, root: ctypes.c_void_p, name: str, *, require_unique: bool = True) -> ctypes.c_void_p | None:
            allocated = oleaut32.SysAllocString(name)
            condition = ctypes.c_void_p()
            found = ctypes.c_void_p()
            try:
                value = VARIANT(vt=VT_BSTR, bstrVal=allocated)
                create = com_method(
                    self.automation,
                    23,
                    ctypes.c_int,
                    VARIANT,
                    ctypes.POINTER(ctypes.c_void_p),
                )
                result = create(self.automation, UIA_NAME_PROPERTY_ID, value, ctypes.byref(condition))
                if not succeeded(result) or not condition.value:
                    return None
                find_all = com_method(
                    root,
                    6,
                    ctypes.c_int,
                    ctypes.c_void_p,
                    ctypes.POINTER(ctypes.c_void_p),
                )
                result = find_all(root, TREE_SCOPE_DESCENDANTS, condition, ctypes.byref(found))
                if not succeeded(result) or not found.value:
                    return None
                length = ctypes.c_int()
                get_length = com_method(found, 3, ctypes.POINTER(ctypes.c_int))
                if not succeeded(get_length(found, ctypes.byref(length))):
                    return None
                get_element = com_method(found, 4, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p))
                match = None
                for index in range(length.value):
                    element = ctypes.c_void_p()
                    if not succeeded(get_element(found, index, ctypes.byref(element))) or not element.value:
                        continue
                    control_type = ctypes.c_int()
                    get_control_type = com_method(element, 21, ctypes.POINTER(ctypes.c_int))
                    if (succeeded(get_control_type(element, ctypes.byref(control_type)))
                            and control_type.value == UIA_BUTTON_CONTROL_TYPE_ID
                            and self._bool_property(element, UIA_IS_OFFSCREEN_PROPERTY_ID) is False):
                        if not require_unique:
                            return element
                        if match is not None:
                            release(match)
                            release(element)
                            return None  # Never pick the first of conflicting controls.
                        match = element
                        continue
                    release(element)
                return match
            finally:
                release(found)
                release(condition)
                oleaut32.SysFreeString(allocated)

        @staticmethod
        def _process_name(process_id: int) -> str:
            handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, process_id)
            if not handle:
                return ""
            try:
                size = wintypes.DWORD(32768)
                buffer = ctypes.create_unicode_buffer(size.value)
                if not kernel32.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                    return ""
                return os.path.basename(buffer.value).casefold()
            finally:
                kernel32.CloseHandle(handle)

        def _window_handles(self) -> list[tuple[int, int]]:
            handles: list[tuple[int, int]] = []
            callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

            @callback_type
            def visit(hwnd: int, _lparam: int) -> bool:
                if not user32.IsWindowVisible(hwnd):
                    return True
                process_id = wintypes.DWORD()
                user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
                if self._process_name(process_id.value) in {"chatgpt.exe", "codex.exe"}:
                    handles.append((int(hwnd), process_id.value))
                return True

            user32.EnumWindows(visit, 0)
            return handles

        def _root_from_handle(self, hwnd: int) -> ctypes.c_void_p | None:
            root = ctypes.c_void_p()
            element_from_handle = com_method(
                self.automation,
                6,
                wintypes.HWND,
                ctypes.POINTER(ctypes.c_void_p),
            )
            result = element_from_handle(self.automation, hwnd, ctypes.byref(root))
            return root if succeeded(result) and root.value else None

        def find_candidates(self) -> list[SidebarCandidate]:
            for root in self._roots.values():
                release(root)
            self._roots.clear()
            candidates: list[SidebarCandidate] = []
            for hwnd, process_id in self._window_handles():
                root = self._root_from_handle(hwnd)
                if root is None:
                    continue
                hide = self._named_element(root, "Hide sidebar")
                show = self._named_element(root, "Show sidebar")
                if (hide is None) == (show is None):
                    release(hide)
                    release(show)
                    release(root)
                    continue
                state = "open" if hide is not None else "hidden"
                release(hide)
                release(show)
                self._roots[hwnd] = root
                candidates.append(SidebarCandidate(process_id, state, hwnd))
            return candidates

        def read_state(self, candidate: SidebarCandidate) -> str:
            root = self._roots.get(int(candidate.token))
            if root is None:
                return "unknown"
            hide = self._named_element(root, "Hide sidebar")
            show = self._named_element(root, "Show sidebar")
            try:
                if show is not None and hide is None:
                    return "hidden"
                if hide is not None and show is None:
                    return "open"
                return "unknown"
            finally:
                release(hide)
                release(show)

        def invoke_named(self, candidate: SidebarCandidate, name: str) -> bool:
            root = self._roots.get(int(candidate.token))
            if root is None:
                return False
            control = self._named_element(root, name)
            if control is None:
                return False
            pattern = ctypes.c_void_p()
            try:
                if self._bool_property(control, UIA_IS_ENABLED_PROPERTY_ID) is not True:
                    return False
                # Invoke the identified control, not a global key chord. No focus stealing.
                get_pattern = com_method(control, 14, ctypes.c_int, ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p))
                result = get_pattern(control, UIA_INVOKE_PATTERN_ID,
                                     ctypes.byref(IID_IUIAUTOMATION_INVOKE_PATTERN), ctypes.byref(pattern))
                if not succeeded(result) or not pattern.value:
                    return False
                return succeeded(com_method(pattern, 3)(pattern))
            finally:
                release(pattern)
                release(control)

        def invoke_hide(self, candidate: SidebarCandidate) -> bool:
            if self.read_state(candidate) != "open":
                return False
            return self.invoke_named(candidate, "Hide sidebar")

        def read_layout(self, candidate: SidebarCandidate) -> tuple[str, str | None]:
            root = self._roots.get(int(candidate.token))
            if root is None:
                return "unknown", None
            names = set()
            for name in ("Enter split view", "Exit full view", "Show tabs", "Hide tabs",
                         "Enter full view", "New tab", "New tab in full view"):
                control = self._named_element(root, name, require_unique=False)
                if control is not None:
                    names.add(name)
                    release(control)
            return layout_state_from_controls(names)

        def invoke_layout(self, candidate: SidebarCandidate, action: str | None) -> bool:
            state, current_action = self.read_layout(candidate)
            if state not in {"full", "hidden_tabs"} or action != current_action or action is None:
                return False
            return self.invoke_named(candidate, action)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-ms", type=int, default=3000)
    parser.add_argument("--ensure-split", action="store_true", help="GPTDesk only: verify hidden sidebar and split view after native open")
    parser.add_argument("--experience", choices=("desktop-ui", "popout", "web"))
    args = parser.parse_args()
    if args.timeout_ms < 0 or args.timeout_ms > 10000:
        return emit("failed", message="--timeout-ms must be between 0 and 10000.")
    if args.experience in {"popout", "web"} or (args.ensure_split and args.experience != "desktop-ui"):
        return emit("failed", layoutVerified=False, message="Split-view repair requires the explicit desktop-ui destination.")
    if os.name != "nt":
        return emit("unavailable", message="The Codex sidebar helper supports Windows only.")

    backend = None
    try:
        backend = WindowsUiaBackend()
        operation = ensure_desk_layout if args.ensure_split else ensure_sidebar_hidden
        status, details = operation(backend, args.timeout_ms)
        return emit(status, **details)
    except Exception as error:
        return emit("failed", message=f"Codex sidebar inspection failed: {error}")
    finally:
        if backend is not None:
            backend.close()


if __name__ == "__main__":
    sys.exit(main())
