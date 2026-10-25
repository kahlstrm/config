"""Scenario registry: every module in this package exports a SCENARIOS list."""

import importlib
import pkgutil

from .kit import Scenario

__all__ = ["SCENARIOS", "Scenario"]

SCENARIOS = {
    scenario.id: scenario
    for module in sorted(name for _, name, _ in pkgutil.iter_modules(__path__) if name != "kit")
    for scenario in importlib.import_module(f"{__name__}.{module}").SCENARIOS
}
