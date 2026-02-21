"""Log file monitoring and deadlock detection."""

import fnmatch
import random
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

from .keyboard import KeyboardHandler
from log_analyzer.models import FileStatus


class LogMonitor:
    """Monitors log files for changes to detect simulation deadlock."""

    DEFAULT_LOG_DIR = (
        Path(__file__).parent.parent.parent / "rtl_runner" / "logs" / "fsim_logs"
    )

    def __init__(
        self,
        log_dir: Optional[Path] = None,
        check_interval: float = 2.0,
        deadlock_threshold: float = 30.0,
        extensions: tuple = (".log",),
        include_patterns: Optional[list[str]] = None,
        exclude_patterns: Optional[list[str]] = None,
        verbose: bool = False,
        debug: bool = False,
    ):
        """
        Initialize the log monitor.

        Args:
            log_dir: Directory containing log files
            check_interval: How often to check for changes (seconds)
            deadlock_threshold: Time without changes to consider deadlock (seconds)
            extensions: File extensions to monitor
            include_patterns: Glob patterns to include (if set, only matching files are monitored)
            exclude_patterns: Glob patterns to exclude
            verbose: Print detailed information
            debug: Enable debug logging to /tmp/fsim_log_analyzer_debug.log
        """
        self.log_dir = Path(log_dir) if log_dir else self.DEFAULT_LOG_DIR
        self.check_interval = check_interval
        self.deadlock_threshold = deadlock_threshold
        self.extensions = extensions
        self.include_patterns = include_patterns or []
        self.exclude_patterns = exclude_patterns or []
        self.verbose = verbose
        self.debug = debug

        if self.debug:
            debug_log = "/tmp/fsim_log_analyzer_debug.log"
            KeyboardHandler.enable_debug(debug_log)
            KeyboardHandler._debug(f"Debug logging enabled to {debug_log}")

        self.file_statuses: dict[str, FileStatus] = {}
        self.last_any_change: float = time.time()
        self.monitoring_start: float = 0

        # Selection state for keyboard navigation
        self.selection_mode: bool = False
        self.selected_index: int = 0
        self.selectable_files: list[Path] = []

    def _matches_pattern(self, filename: str, patterns: list[str]) -> bool:
        """Check if filename matches any of the given glob patterns."""
        for pattern in patterns:
            if fnmatch.fnmatch(filename, pattern):
                return True
        return False

    def _get_log_files(self) -> list[Path]:
        """Get all log files in the directory, filtered by include/exclude patterns."""
        if not self.log_dir.exists():
            raise FileNotFoundError(f"Log directory not found: {self.log_dir}")

        files = []
        for ext in self.extensions:
            files.extend(self.log_dir.glob(f"*{ext}"))

        # Apply include patterns (if specified, only keep matching files)
        if self.include_patterns:
            files = [
                f
                for f in files
                if self._matches_pattern(f.name, self.include_patterns)
            ]

        # Apply exclude patterns
        if self.exclude_patterns:
            files = [
                f
                for f in files
                if not self._matches_pattern(f.name, self.exclude_patterns)
            ]

        return sorted(files)

    def _get_file_stat(self, path: Path) -> tuple[int, float]:
        """Get file size and modification time."""
        try:
            stat = path.stat()
            return stat.st_size, stat.st_mtime
        except OSError:
            return 0, 0

    def _open_file_in_vscode(self, file_path: Path):
        """Open a file in VS Code."""
        try:
            subprocess.Popen(
                ['code', str(file_path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True
            )
        except Exception:
            pass

    def _handle_keyboard_input(self, key: Optional[str]) -> bool:
        """
        Handle keyboard input for file selection.

        Args:
            key: Key pressed by user

        Returns:
            True if should continue monitoring, False if should exit
        """
        if key is None:
            return True

        KeyboardHandler._debug(f"_handle_keyboard_input: key={repr(key)}, selection_mode={self.selection_mode}, selected_index={self.selected_index}")

        # Handle Ctrl+C
        if key == 'CTRL_C':
            KeyboardHandler._debug("Handling CTRL_C - exiting")
            return False

        # If not in selection mode, any navigation key enters selection mode
        if not self.selection_mode:
            KeyboardHandler._debug(f"Not in selection mode, checking if key enters selection mode")
            if key in ['UP', 'DOWN', 'j', 'k'] and self.selectable_files:
                self.selection_mode = True
                self.selected_index = 0
                KeyboardHandler._debug(f"Entered selection mode! selectable_files count={len(self.selectable_files)}")
            return True

        # In selection mode - handle navigation and selection
        KeyboardHandler._debug("In selection mode, handling navigation")
        if key in ['UP', 'k']:
            if self.selectable_files:
                old_index = self.selected_index
                self.selected_index = (self.selected_index - 1) % len(self.selectable_files)
                KeyboardHandler._debug(f"UP/k: moved from {old_index} to {self.selected_index}")
        elif key in ['DOWN', 'j']:
            if self.selectable_files:
                old_index = self.selected_index
                self.selected_index = (self.selected_index + 1) % len(self.selectable_files)
                KeyboardHandler._debug(f"DOWN/j: moved from {old_index} to {self.selected_index}")
        elif key in ['ENTER', 'SPACE']:
            if self.selectable_files and 0 <= self.selected_index < len(self.selectable_files):
                selected_file = self.selectable_files[self.selected_index]
                KeyboardHandler._debug(f"Opening file: {selected_file}")
                self._open_file_in_vscode(selected_file)
        elif key == 'q':
            # Exit selection mode
            KeyboardHandler._debug("Exiting selection mode")
            self.selection_mode = False
            self.selected_index = 0

        return True

    def _update_file_status(self, path: Path, current_time: float) -> bool:
        """
        Update the status of a file and return whether it changed.

        Returns:
            True if the file changed since last check
        """
        size, mtime = self._get_file_stat(path)
        path_str = str(path)

        if path_str not in self.file_statuses:
            self.file_statuses[path_str] = FileStatus(
                path=path,
                size=size,
                mtime=mtime,
                last_check=current_time,
                changed_since_last_check=True,
            )
            return True

        status = self.file_statuses[path_str]
        changed = (size != status.size) or (mtime != status.mtime)

        status.size = size
        status.mtime = mtime
        status.last_check = current_time
        status.changed_since_last_check = changed

        return changed

    def check_once(self) -> dict:
        """
        Perform a single check of all log files.

        Returns:
            Dictionary with check results
        """
        current_time = time.time()
        files = self._get_log_files()

        changed_files = []
        unchanged_files = []

        for f in files:
            if self._update_file_status(f, current_time):
                changed_files.append(f)
            else:
                unchanged_files.append(f)

        if changed_files:
            self.last_any_change = current_time

        time_since_change = current_time - self.last_any_change

        return {
            "timestamp": current_time,
            "total_files": len(files),
            "changed_files": changed_files,
            "unchanged_files": unchanged_files,
            "time_since_any_change": time_since_change,
            "potential_deadlock": time_since_change >= self.deadlock_threshold,
        }

    def _format_time(self, seconds: float) -> str:
        """Format seconds into human-readable string."""
        if seconds < 60:
            return f"{seconds:.1f}s"
        elif seconds < 3600:
            mins = int(seconds // 60)
            secs = seconds % 60
            return f"{mins}m {secs:.1f}s"
        else:
            hours = int(seconds // 3600)
            mins = int((seconds % 3600) // 60)
            return f"{hours}h {mins}m"

    def _print_status(self, result: dict, clear_screen: bool = True):
        """Print the current monitoring status."""
        if clear_screen:
            # ANSI escape code to clear screen and move cursor to top
            print("\033[2J\033[H", end="")

        elapsed = time.time() - self.monitoring_start
        print("=" * 70)
        print(f"  FSIM Log Monitor - Elapsed: {self._format_time(elapsed)}")
        print("=" * 70)
        print(f"  Log directory: {self.log_dir}")
        print(f"  Monitoring files: {result['total_files']}")
        if self.include_patterns:
            print(f"  Include: {', '.join(self.include_patterns)}")
        if self.exclude_patterns:
            print(f"  Exclude: {', '.join(self.exclude_patterns)}")
        print(
            f"  Check interval: {self.check_interval}s | Deadlock threshold: {self.deadlock_threshold}s"
        )
        print("-" * 70)

        time_since_change = result["time_since_any_change"]

        if result["potential_deadlock"]:
            print(f"\n  [!!! POTENTIAL DEADLOCK !!!]")
            print(
                f"  No log file changes for {self._format_time(time_since_change)}"
            )
            print(f"  Threshold: {self.deadlock_threshold}s")
        else:
            progress_bar_width = 40
            progress = min(time_since_change / self.deadlock_threshold, 1.0)
            filled = int(progress_bar_width * progress)
            bar = "█" * filled + "░" * (progress_bar_width - filled)
            print(f"\n  Status: ACTIVE")
            print(
                f"  Time since last change: {self._format_time(time_since_change)}"
            )
            print(f"  Deadlock timer: [{bar}] {progress*100:.0f}%")

        # Update selectable files list
        self.selectable_files = result["changed_files"][:10]  # Limit to 10 files

        if result["changed_files"]:
            print(
                f"\n  Recently changed files ({len(result['changed_files'])}):"
            )
            # Show up to 10 files with numbers for selection
            display_count = min(len(result["changed_files"]), 10)
            for i in range(display_count):
                f = result["changed_files"][i]
                # Show selection indicator if in selection mode
                if self.selection_mode and i == self.selected_index:
                    indicator = "→"
                else:
                    indicator = " "
                print(f"    {indicator} [{i+1}] {f.name}")

            if len(result["changed_files"]) > 10:
                print(f"    ... and {len(result['changed_files']) - 10} more")

        print("\n" + "-" * 70)
        if self.selection_mode:
            print("  ↑↓/jk: navigate | Enter/Space: open in VS Code | q: exit selection")
        else:
            print("  ↑↓/jk: enter selection mode | Ctrl+C: stop monitoring")
        print("=" * 70)
        sys.stdout.flush()  # Ensure output is displayed immediately

    def monitor(self, duration: Optional[float] = None) -> bool:
        """
        Start monitoring log files continuously.

        Args:
            duration: Maximum monitoring duration in seconds (None for indefinite)

        Returns:
            True if deadlock was detected, False otherwise
        """
        print(f"Starting log monitor...")
        print(f"  Directory: {self.log_dir}")
        print(f"  Check interval: {self.check_interval}s")
        print(f"  Deadlock threshold: {self.deadlock_threshold}s")
        print()

        self.monitoring_start = time.time()
        self.last_any_change = time.time()
        deadlock_detected = False

        # Enable cbreak mode for responsive keyboard input
        KeyboardHandler.enable_cbreak_mode()

        try:
            # Do initial file check so result is never None
            result = self.check_once()
            self._print_status(result)
            last_check_time = time.time()

            while True:
                current_time = time.time()

                # Check files at regular intervals
                if current_time - last_check_time >= self.check_interval:
                    result = self.check_once()
                    self._print_status(result)
                    last_check_time = current_time

                    if result and result["potential_deadlock"]:
                        deadlock_detected = True

                # Check for keyboard input frequently (every 100ms)
                key = KeyboardHandler.get_key(timeout=0.1)
                if not self._handle_keyboard_input(key):
                    # User pressed Ctrl+C
                    break

                # If navigation key was pressed, redraw immediately
                if key in ['UP', 'DOWN', 'j', 'k', 'q', 'ENTER', 'SPACE']:
                    KeyboardHandler._debug(f"Navigation key {key} pressed, redrawing...")
                    self._print_status(result)

                if (
                    duration
                    and (time.time() - self.monitoring_start) >= duration
                ):
                    print("\nMonitoring duration reached.")
                    break

        except KeyboardInterrupt:
            pass
        finally:
            # Always restore terminal settings
            KeyboardHandler.restore_terminal()
            print("\n\nMonitoring stopped by user.")
            sys.stdout.flush()

        return deadlock_detected

    def get_active_files(
        self, since_seconds: float = 60.0
    ) -> list[FileStatus]:
        """
        Get files that have been modified within the given time window.

        Args:
            since_seconds: Time window in seconds

        Returns:
            List of FileStatus for recently modified files
        """
        current_time = time.time()
        cutoff = current_time - since_seconds

        active = []
        for status in self.file_statuses.values():
            if status.mtime >= cutoff:
                active.append(status)

        return sorted(active, key=lambda x: x.mtime, reverse=True)

    def summary(self) -> dict:
        """
        Get a summary of all monitored files.

        Returns:
            Dictionary with summary statistics
        """
        files = self._get_log_files()

        total_size = 0
        non_empty_count = 0

        for f in files:
            size, _ = self._get_file_stat(f)
            total_size += size
            if size > 0:
                non_empty_count += 1

        return {
            "log_dir": str(self.log_dir),
            "total_files": len(files),
            "non_empty_files": non_empty_count,
            "empty_files": len(files) - non_empty_count,
            "total_size_bytes": total_size,
            "total_size_mb": total_size / (1024 * 1024),
        }


class DebugTestDirectory:
    """Creates and manages a test directory with simulated file activity for debugging."""

    def __init__(self):
        self.test_dir = Path(tempfile.mkdtemp(prefix="fsim_debug_"))
        self.stop_event = threading.Event()
        self.thread = None
        self.files = []

    def create_test_files(self, count: int = 10):
        """Create test log files."""
        print(f"Creating {count} test files in {self.test_dir}")

        # Create various test files with realistic names
        test_names = [
            "testbench.u_core.u_stage1.log",
            "testbench.u_core.u_stage2.log",
            "testbench.u_core.u_mem.log",
            "testbench.u_noc.u_router[0].log",
            "testbench.u_noc.u_router[1].log",
            "testbench.u_imce.u_ctrl.log",
            "testbench.u_imce.u_datapath.log",
            "testbench.u_bridge.u_axi.log",
            "testbench.u_bridge.u_demux.log",
            "run.log",
        ]

        for i, name in enumerate(test_names[:count]):
            file_path = self.test_dir / name
            with open(file_path, 'w') as f:
                f.write(f"[0] Test log file: {name}\n")
                f.write(f"[100] Initialized at {time.time()}\n")
            self.files.append(file_path)

        print(f"Created {len(self.files)} test files")

    def _update_files_loop(self):
        """Background thread that periodically updates random files."""
        cycle = 0
        while not self.stop_event.is_set():
            num_updates = random.randint(1, min(3, len(self.files)))
            files_to_update = random.sample(self.files, num_updates)

            for file_path in files_to_update:
                try:
                    with open(file_path, 'a') as f:
                        timestamp = int(time.time() * 1000)
                        f.write(f"[{timestamp}] Cycle {cycle}: Random activity\n")
                except Exception:
                    pass

            cycle += 1
            time.sleep(random.uniform(0.5, 2.0))

    def start_activity(self):
        """Start background thread to simulate file activity."""
        if self.thread is None or not self.thread.is_alive():
            self.stop_event.clear()
            self.thread = threading.Thread(target=self._update_files_loop, daemon=True)
            self.thread.start()
            print("Started simulated file activity (updates every 0.5-2s)")

    def stop_activity(self):
        """Stop background activity thread."""
        if self.thread and self.thread.is_alive():
            self.stop_event.set()
            self.thread.join(timeout=2.0)

    def cleanup(self):
        """Clean up test directory."""
        self.stop_activity()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.cleanup()
