"""Keyboard input handling for interactive terminal UI."""

import select
import sys
import termios
import time
import tty
from typing import Optional


class KeyboardHandler:
    """Handles non-blocking keyboard input for interactive selection."""

    debug_file = None
    _original_settings = None

    def __init__(self):
        self.fd = sys.stdin.fileno()

    @staticmethod
    def enable_debug(log_file: str):
        """Enable debug logging to a file."""
        KeyboardHandler.debug_file = open(log_file, 'w')

    @staticmethod
    def _debug(msg: str):
        """Write debug message to log file."""
        if KeyboardHandler.debug_file:
            KeyboardHandler.debug_file.write(f"[{time.time():.3f}] {msg}\n")
            KeyboardHandler.debug_file.flush()

    @staticmethod
    def enable_cbreak_mode():
        """Enable cbreak mode: no echo, no line buffering, but ANSI codes work."""
        fd = sys.stdin.fileno()
        try:
            KeyboardHandler._original_settings = termios.tcgetattr(fd)
            tty.setcbreak(fd)
            KeyboardHandler._debug("Enabled cbreak mode")
        except Exception as e:
            KeyboardHandler._debug(f"ERROR enabling cbreak mode: {e}")

    @staticmethod
    def restore_terminal():
        """Restore original terminal settings."""
        if KeyboardHandler._original_settings:
            fd = sys.stdin.fileno()
            try:
                termios.tcsetattr(fd, termios.TCSADRAIN, KeyboardHandler._original_settings)
                KeyboardHandler._debug("Restored terminal settings")
            except Exception as e:
                KeyboardHandler._debug(f"ERROR restoring terminal: {e}")

    @staticmethod
    def get_key(timeout: float = 0.0) -> Optional[str]:
        """
        Get a key press without blocking.
        Assumes terminal is already in cbreak mode.

        Args:
            timeout: Time to wait for input (0 = non-blocking)

        Returns:
            Key string or None if no input available.
            Special keys: 'UP', 'DOWN', 'ENTER', 'SPACE', etc.
        """
        try:
            KeyboardHandler._debug(f"get_key called with timeout={timeout}")

            # Check if input is available
            KeyboardHandler._debug("Calling select.select...")
            ready, _, _ = select.select([sys.stdin], [], [], timeout)
            KeyboardHandler._debug(f"select returned: ready={len(ready)}")

            if not ready:
                return None

            KeyboardHandler._debug("Input available, reading...")

            # Read the key (terminal already in cbreak mode)
            ch = sys.stdin.read(1)
            KeyboardHandler._debug(f"Read character: {repr(ch)} (ord={ord(ch) if ch else 'None'})")

            # Handle escape sequences (arrow keys, etc.)
            if ch == '\x1b':  # ESC
                KeyboardHandler._debug("ESC sequence detected")
                # Try to read the rest of the escape sequence
                ready, _, _ = select.select([sys.stdin], [], [], 0.05)
                if ready:
                    ch2 = sys.stdin.read(1)
                    KeyboardHandler._debug(f"ESC+{repr(ch2)}")
                    if ch2 == '[':
                        ready, _, _ = select.select([sys.stdin], [], [], 0.05)
                        if ready:
                            ch3 = sys.stdin.read(1)
                            KeyboardHandler._debug(f"ESC+[+{repr(ch3)}")
                            if ch3 == 'A':
                                KeyboardHandler._debug("Returning UP")
                                return 'UP'
                            elif ch3 == 'B':
                                KeyboardHandler._debug("Returning DOWN")
                                return 'DOWN'
                            elif ch3 == 'C':
                                KeyboardHandler._debug("Returning RIGHT")
                                return 'RIGHT'
                            elif ch3 == 'D':
                                KeyboardHandler._debug("Returning LEFT")
                                return 'LEFT'
                KeyboardHandler._debug("Returning ESC")
                return 'ESC'
            elif ch == '\r' or ch == '\n':
                KeyboardHandler._debug("Returning ENTER")
                return 'ENTER'
            elif ch == ' ':
                KeyboardHandler._debug("Returning SPACE")
                return 'SPACE'
            elif ch == '\x03':  # Ctrl+C
                KeyboardHandler._debug("Returning CTRL_C")
                return 'CTRL_C'
            elif ch == 'q' or ch == 'Q':
                KeyboardHandler._debug("Returning q")
                return 'q'
            elif ch == 'j':
                KeyboardHandler._debug("Returning j")
                return 'j'
            elif ch == 'k':
                KeyboardHandler._debug("Returning k")
                return 'k'
            else:
                KeyboardHandler._debug(f"Returning character: {repr(ch)}")
                return ch
        except Exception as e:
            KeyboardHandler._debug(f"ERROR in get_key: {type(e).__name__}: {e}")
            return None
