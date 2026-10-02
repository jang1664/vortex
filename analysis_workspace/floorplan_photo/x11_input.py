"""Small XTEST input helper for an isolated Vivado virtual display."""

import ctypes as C
from ctypes.util import find_library
import time


class X11Input:
    def __init__(self, display: str):
        self.x11 = C.CDLL(find_library("X11"))
        self.xtest = C.CDLL(find_library("Xtst"))
        self.x11.XOpenDisplay.argtypes = [C.c_char_p]
        self.x11.XOpenDisplay.restype = C.c_void_p
        self.x11.XCloseDisplay.argtypes = [C.c_void_p]
        self.x11.XFlush.argtypes = [C.c_void_p]
        self.x11.XDefaultRootWindow.argtypes = [C.c_void_p]
        self.x11.XDefaultRootWindow.restype = C.c_ulong
        self.x11.XGetImage.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.c_int,
                                       C.c_uint, C.c_uint, C.c_ulong, C.c_int]
        self.x11.XGetImage.restype = C.c_void_p
        self.x11.XGetPixel.argtypes = [C.c_void_p, C.c_int, C.c_int]
        self.x11.XGetPixel.restype = C.c_ulong
        self.x11.XDestroyImage.argtypes = [C.c_void_p]
        self.x11.XStringToKeysym.argtypes = [C.c_char_p]
        self.x11.XStringToKeysym.restype = C.c_ulong
        self.x11.XKeysymToKeycode.argtypes = [C.c_void_p, C.c_ulong]
        self.x11.XKeysymToKeycode.restype = C.c_uint
        self.xtest.XTestFakeKeyEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.xtest.XTestFakeButtonEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.xtest.XTestFakeMotionEvent.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong]
        self.display = self.x11.XOpenDisplay(display.encode())
        if not self.display:
            raise RuntimeError(f"Cannot open X display {display}")

    def close(self):
        if self.display:
            self.x11.XCloseDisplay(self.display)
            self.display = None

    def click(self, x: int, y: int, *, button: int = 1, count: int = 1):
        self.xtest.XTestFakeMotionEvent(self.display, -1, x, y, 0)
        for _ in range(count):
            self.xtest.XTestFakeButtonEvent(self.display, button, 1, 0)
            self.xtest.XTestFakeButtonEvent(self.display, button, 0, 0)
            self.x11.XFlush(self.display)
            time.sleep(0.08)

    def key(self, name: str):
        symbol = self.x11.XStringToKeysym(name.encode())
        code = self.x11.XKeysymToKeycode(self.display, symbol)
        if not code:
            raise ValueError(f"Unknown X key: {name}")
        self.xtest.XTestFakeKeyEvent(self.display, code, 1, 0)
        self.xtest.XTestFakeKeyEvent(self.display, code, 0, 0)
        self.x11.XFlush(self.display)

    def pixels(self, x: int, y: int, width: int = 1, height: int = 1) -> list[tuple[int, int, int]]:
        root = self.x11.XDefaultRootWindow(self.display)
        image = self.x11.XGetImage(self.display, root, x, y, width, height, 0xFFFFFFFF, 2)
        if not image:
            raise RuntimeError("Cannot read the Xvfb screen")
        try:
            result = []
            for row in range(height):
                for col in range(width):
                    value = self.x11.XGetPixel(image, col, row)
                    result.append(((value >> 16) & 255, (value >> 8) & 255, value & 255))
            return result
        finally:
            self.x11.XDestroyImage(image)
