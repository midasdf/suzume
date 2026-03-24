import os
import sys
from wptrunner.browsers.base import NullBrowser, ExecutorBrowser


def create_product():
    """Entry point callable for wptrunner product discovery.
    Returns a Product instance from this module's __wptrunner__ dict."""
    from wptrunner.products import Product
    return Product._from_dunder_wptrunner(sys.modules[__name__])


__wptrunner__ = {
    "product": "suzume",
    "check_args": "check_args",
    "browser": "SuzumeBrowser",
    "browser_kwargs": "browser_kwargs",
    "executor": {
        "testharness": "SuzumeTestharnessExecutor",
        "reftest": "SuzumeRefTestExecutor",
        "crashtest": "SuzumeCrashtestExecutor",
    },
    "executor_kwargs": "executor_kwargs",
    "env_extras": "env_extras",
    "env_options": "env_options",
    "timeout_multiplier": "get_timeout_multiplier",
    "update_properties": "update_properties",
}


def check_args(**kwargs):
    pass


def browser_kwargs(logger, test_type, run_info_data, config, **kwargs):
    return {
        "binary": kwargs.get("binary"),
        "binary_args": kwargs.get("binary_args", []),
    }


def executor_kwargs(logger, test_type, test_environment, run_info_data, subsuite,
                     **kwargs):
    return {
        "binary": kwargs.get("binary"),
        "binary_args": kwargs.get("binary_args", []),
    }


def env_extras(**kwargs):
    return []


def env_options():
    return {
        "server_host": "127.0.0.1",
        "testharnessreport": "testharnessreport-suzume.js",
        "supports_debugger": False,
    }


def get_timeout_multiplier(test_type, run_info_data, **kwargs):
    return kwargs.get("timeout_multiplier", 2)


def update_properties():
    return (["os", "processor"], {"os": ["version"], "processor": ["bits"]})


class SuzumeBrowser(NullBrowser):
    def __init__(self, logger, binary=None, binary_args=None, **kwargs):
        super().__init__(logger, **kwargs)
        self.binary = binary or "suzume"
        self.binary_args = binary_args or []

    def executor_browser(self):
        return ExecutorBrowser, {
            "binary": self.binary,
            "binary_args": self.binary_args,
        }


# Import executors so wptrunner can find them
from .executor import (  # noqa: E402, F401
    SuzumeTestharnessExecutor,
    SuzumeRefTestExecutor,
    SuzumeCrashtestExecutor,
)
