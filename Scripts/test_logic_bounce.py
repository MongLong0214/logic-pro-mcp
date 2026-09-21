#!/usr/bin/env python3
from __future__ import annotations

import unittest

from logic_bounce_main_test import LogicBounceMainTests
from logic_bounce_support_test import LogicBounceSupportTests
from logic_bounce_ui_test import LogicBounceUITests

__all__ = [
    "LogicBounceMainTests",
    "LogicBounceSupportTests",
    "LogicBounceUITests",
]


if __name__ == "__main__":
    unittest.main()
