import json
import os
import subprocess
import tempfile
import threading
import time

from wptrunner.executors.base import (
    TestExecutor,
    RefTestExecutor,
    CrashtestExecutor,
    testharness_result_converter,
    reftest_result_converter,
)


class SuzumeProcessMixin:
    """Common process management for suzume executors."""

    def _build_command(self, url):
        cmd = [self.binary, "--wpt-mode", url]
        if self.binary_args:
            cmd.extend(self.binary_args)
        return cmd

    def _build_env(self):
        env = os.environ.copy()
        if not hasattr(self, "display_num"):
            self.display_num = int(os.environ.get("WPT_DISPLAY", "98"))
        env["DISPLAY"] = f":{self.display_num}"
        return env

    def _setup_display(self):
        """Start a dedicated Xvfb instance for this executor."""
        self.display_num = 100 + getattr(self, "_manager_number", 0)
        self.xvfb_proc = subprocess.Popen(
            ["Xvfb", f":{self.display_num}", "-screen", "0", "800x600x24", "-ac"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(0.5)

    def _teardown_display(self):
        """Kill the dedicated Xvfb instance."""
        if hasattr(self, "xvfb_proc") and self.xvfb_proc:
            self.xvfb_proc.kill()
            self.xvfb_proc.wait()
            self.xvfb_proc = None


class SuzumeTestharnessExecutor(TestExecutor, SuzumeProcessMixin):
    """Execute testharness.js tests by spawning suzume per test."""

    convert_result = testharness_result_converter

    def __init__(self, logger, browser, server_config, timeout_multiplier=1,
                 debug_info=None, **kwargs):
        super().__init__(logger, browser, server_config, timeout_multiplier,
                         debug_info, **kwargs)
        self.binary = browser.binary
        self.binary_args = browser.binary_args
        self.result_data = None
        self.result_flag = threading.Event()
        self._manager_number = kwargs.get("manager_number", 0)

    def setup(self, runner, protocol=None):
        super().setup(runner, protocol)
        self._setup_display()

    def teardown(self):
        self._teardown_display()
        super().teardown()

    def is_alive(self):
        return True

    def do_test(self, test):
        timeout = test.timeout * self.timeout_multiplier + 5
        self.result_data = None
        self.result_flag = threading.Event()

        test_url = self.test_url(test)
        cmd = self._build_command(test_url)
        env = self._build_env()

        try:
            proc = subprocess.Popen(
                cmd, env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            )
        except OSError as e:
            self.logger.error(f"Failed to start suzume: {e}")
            return self.convert_result(test, {"status": "ERROR", "message": str(e)})

        reader = threading.Thread(
            target=self._read_output, args=(proc.stdout,), daemon=True
        )
        reader.start()

        self.result_flag.wait(timeout)

        if proc.poll() is None:
            proc.kill()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

        if self.result_data is not None:
            return self.convert_result(test, self.result_data)
        else:
            return self.convert_result(test, {
                "status": "TIMEOUT",
                "message": "Test timed out",
                "test": test.url,
                "tests": [],
            })

    def _read_output(self, pipe):
        prefix = "ALERT: RESULT: "
        try:
            for raw_line in pipe:
                line = raw_line.decode("utf-8", "replace").rstrip()
                if line.startswith(prefix):
                    try:
                        data = json.loads(line[len(prefix):])
                        # data format: [url, harness_status, message, stack, [[name, status, msg, stack], ...]]
                        if isinstance(data, list) and len(data) >= 5:
                            self.result_data = data
                        self.result_flag.set()
                        return
                    except json.JSONDecodeError:
                        pass
        except (IOError, ValueError):
            pass


class SuzumeRefTestExecutor(RefTestExecutor, SuzumeProcessMixin):
    """Execute reftests by capturing screenshots from suzume."""

    convert_result = reftest_result_converter

    def __init__(self, logger, browser, server_config, timeout_multiplier=1,
                 debug_info=None, **kwargs):
        super().__init__(logger, browser, server_config, timeout_multiplier,
                         debug_info, **kwargs)
        self.binary = browser.binary
        self.binary_args = browser.binary_args
        self._manager_number = kwargs.get("manager_number", 0)

    def setup(self, runner, protocol=None):
        super().setup(runner, protocol)
        self._setup_display()

    def teardown(self):
        self._teardown_display()
        super().teardown()

    def is_alive(self):
        return True

    def screenshot(self, test, viewport_size, dpi, page_ranges):
        test_url = self.test_url(test)
        return self._capture_screenshot(test_url)

    def _capture_screenshot(self, url):
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            screenshot_path = f.name

        try:
            cmd = [self.binary, "--wpt-mode", "--screenshot", screenshot_path, url]
            if self.binary_args:
                cmd.extend(self.binary_args)
            env = self._build_env()

            proc = subprocess.run(
                cmd, env=env, timeout=30,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

            if os.path.exists(screenshot_path) and os.path.getsize(screenshot_path) > 0:
                with open(screenshot_path, "rb") as f:
                    import base64
                    return base64.b64encode(f.read()).decode("ascii")
        except subprocess.TimeoutExpired:
            pass
        finally:
            if os.path.exists(screenshot_path):
                os.unlink(screenshot_path)

        return None


class SuzumeCrashtestExecutor(CrashtestExecutor, SuzumeProcessMixin):
    """Execute crashtests by loading the page and checking for crashes."""

    def __init__(self, logger, browser, server_config, timeout_multiplier=1,
                 debug_info=None, **kwargs):
        super().__init__(logger, browser, server_config, timeout_multiplier,
                         debug_info, **kwargs)
        self.binary = browser.binary
        self.binary_args = browser.binary_args
        self._manager_number = kwargs.get("manager_number", 0)

    def setup(self, runner, protocol=None):
        super().setup(runner, protocol)
        self._setup_display()

    def teardown(self):
        self._teardown_display()
        super().teardown()

    def is_alive(self):
        return True

    def do_test(self, test):
        timeout = test.timeout * self.timeout_multiplier + 5
        test_url = self.test_url(test)
        cmd = self._build_command(test_url)
        env = self._build_env()

        try:
            result = subprocess.run(
                cmd, env=env, timeout=timeout,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if result.returncode < 0:
                # Negative return code = killed by signal (crash)
                return "CRASH", []
            return "PASS", []
        except subprocess.TimeoutExpired:
            return "TIMEOUT", []
        except OSError as e:
            return "ERROR", []
