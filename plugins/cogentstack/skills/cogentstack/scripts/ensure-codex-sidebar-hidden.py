"""Inspect the Codex accessibility tree and close its sidebar only when open."""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import sys
import time
from ctypes import wintypes
from dataclasses import dataclass


EXIT_CODES = {"hidden": 0, "already_hidden": 0, "unavailable": 2, "ambiguous": 3, "failed": 4}


def emit(status: str, **details: object) -> int:
    print(json.dumps({"status": status, **details}, separators=(",", ":")))
    return EXIT_CODES[status]


@dataclass
class SidebarCandidate:
    process_id: int
    state: str
    token: object


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
        return "ambiguous", {"message": "More than one accessible Codex window exposes a sidebar state.", "candidateCount": len(candidates)}
    candidate = candidates[0]
    if candidate.state == "hidden":
        return "already_hidden", {"processId": candidate.process_id}
    if candidate.state != "open" or not backend.invoke_hide(candidate):
        return "failed", {"message": "The open Codex sidebar could not be closed through its accessibility control.", "processId": candidate.process_id}
    verify_deadline = time.monotonic() + max(0.5, timeout_ms / 1000)
    while time.monotonic() < verify_deadline:
        time.sleep(0.1)
        if backend.read_state(candidate) == "hidden":
            return "hidden", {"processId": candidate.process_id}
    return "failed", {"message": "The Codex sidebar did not report a closed state after the close action.", "processId": candidate.process_id}


if os.name == "nt":
    HRESULT = ctypes.c_long
    UIA_NAME_PROPERTY_ID = 30005
    UIA_BUTTON_CONTROL_TYPE_ID = 50000
    TREE_SCOPE_DESCENDANTS = 0x4
    CLSCTX_INPROC_SERVER = 0x1
    COINIT_APARTMENTTHREADED = 0x2
    RPC_E_CHANGED_MODE = -2147417850
    VT_BSTR = 8
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    INPUT_KEYBOARD = 1
    KEYEVENTF_KEYUP = 0x0002
    VK_CONTROL = 0x11
    VK_SHIFT = 0x10
    VK_S = 0x53

    class GUID(ctypes.Structure):
        _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD), ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

        @classmethod
        def parse(cls, value: str) -> "GUID":
            import uuid
            return cls.from_buffer_copy(uuid.UUID(value).bytes_le)

    class VARIANT_VALUE(ctypes.Union):
        _fields_ = [("llVal", ctypes.c_longlong), ("lVal", ctypes.c_long), ("bstrVal", ctypes.c_void_p), ("punkVal", ctypes.c_void_p)]

    class VARIANT(ctypes.Structure):
        _anonymous_ = ("value",)
        _fields_ = [("vt", wintypes.WORD), ("wReserved1", wintypes.WORD), ("wReserved2", wintypes.WORD), ("wReserved3", wintypes.WORD), ("value", VARIANT_VALUE)]

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD), ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

    class HARDWAREINPUT(ctypes.Structure):
        _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]

    class INPUT_VALUE(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]

    class INPUT(ctypes.Structure):
        _anonymous_ = ("value",)
        _fields_ = [("type", wintypes.DWORD), ("value", INPUT_VALUE)]

    CLSID_CUIAUTOMATION = GUID.parse("ff48dba4-60ef-4201-aa87-54103eef594e")
    IID_IUIAUTOMATION = GUID.parse("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")
    ole32 = ctypes.OleDLL("ole32")
    oleaut32 = ctypes.WinDLL("oleaut32")
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    ole32.CoInitializeEx.argtypes = [ctypes.c_void_p, wintypes.DWORD]
    ole32.CoInitializeEx.restype = HRESULT
    ole32.CoUninitialize.argtypes = []
    ole32.CoCreateInstance.argtypes = [ctypes.POINTER(GUID), ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p)]
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
    user32.GetForegroundWindow.argtypes = []
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
    user32.SendInput.restype = wintypes.UINT

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
            result = ole32.CoCreateInstance(ctypes.byref(CLSID_CUIAUTOMATION), None, CLSCTX_INPROC_SERVER, ctypes.byref(IID_IUIAUTOMATION), ctypes.byref(self.automation))
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

        def _named_element(self, root: ctypes.c_void_p, name: str) -> ctypes.c_void_p | None:
            allocated = oleaut32.SysAllocString(name)
            condition = ctypes.c_void_p()
            found = ctypes.c_void_p()
            try:
                value = VARIANT(vt=VT_BSTR, bstrVal=allocated)
                create = com_method(self.automation, 23, ctypes.c_int, VARIANT, ctypes.POINTER(ctypes.c_void_p))
                result = create(self.automation, UIA_NAME_PROPERTY_ID, value, ctypes.byref(condition))
                if not succeeded(result) or not condition.value:
                    return None
                find_all = com_method(root, 6, ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p))
                result = find_all(root, TREE_SCOPE_DESCENDANTS, condition, ctypes.byref(found))
                if not succeeded(result) or not found.value:
                    return None
                length = ctypes.c_int()
                if not succeeded(com_method(found, 3, ctypes.POINTER(ctypes.c_int))(found, ctypes.byref(length))):
                    return None
                get_element = com_method(found, 4, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p))
                for index in range(length.value):
                    element = ctypes.c_void_p()
                    if not succeeded(get_element(found, index, ctypes.byref(element))) or not element.value:
                        continue
                    control_type = ctypes.c_int()
                    get_control_type = com_method(element, 21, ctypes.POINTER(ctypes.c_int))
                    if succeeded(get_control_type(element, ctypes.byref(control_type))) and control_type.value == UIA_BUTTON_CONTROL_TYPE_ID:
                        return element
                    release(element)
                return None
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
            element_from_handle = com_method(self.automation, 6, wintypes.HWND, ctypes.POINTER(ctypes.c_void_p))
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

        def invoke_hide(self, candidate: SidebarCandidate) -> bool:
            root = self._roots.get(int(candidate.token))
            if root is None:
                return False
            hide = self._named_element(root, "Hide sidebar")
            if hide is None:
                return False
            try:
                if int(user32.GetForegroundWindow()) != int(candidate.token):
                    return False
                keys = ((VK_CONTROL, 0), (VK_SHIFT, 0), (VK_S, 0), (VK_S, KEYEVENTF_KEYUP), (VK_SHIFT, KEYEVENTF_KEYUP), (VK_CONTROL, KEYEVENTF_KEYUP))
                events = (INPUT * len(keys))(*[INPUT(type=INPUT_KEYBOARD, ki=KEYBDINPUT(wVk=key, dwFlags=flags)) for key, flags in keys])
                return user32.SendInput(len(events), events, ctypes.sizeof(INPUT)) == len(events)
            finally:
                release(hide)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-ms", type=int, default=3000)
    args = parser.parse_args()
    if args.timeout_ms < 0 or args.timeout_ms > 10000:
        return emit("failed", message="--timeout-ms must be between 0 and 10000.")
    if os.name != "nt":
        return emit("unavailable", message="The Codex sidebar helper supports Windows only.")
    backend = None
    try:
        backend = WindowsUiaBackend()
        status, details = ensure_sidebar_hidden(backend, args.timeout_ms)
        return emit(status, **details)
    except Exception as error:
        return emit("failed", message=f"Codex sidebar inspection failed: {error}")
    finally:
        if backend is not None:
            backend.close()


if __name__ == "__main__":
    sys.exit(main())
