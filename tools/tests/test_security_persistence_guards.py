import importlib.util
from pathlib import Path
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "test_security_persistence.py"
SPEC = importlib.util.spec_from_file_location("security_persistence_operator", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GuardChecks(unittest.TestCase):
    def test_explicit_isolated_emulator_target_is_allowed(self):
        MODULE.validate_target("emulator-5554", MODULE.VALIDATION_PACKAGE, True)

    def test_physical_serial_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.validate_target("R1234567", MODULE.VALIDATION_PACKAGE, True)

    def test_production_package_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.validate_target("emulator-5554", "com.example.mits_kids_youtube", True)

    def test_implicit_reset_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.validate_target("emulator-5554", MODULE.VALIDATION_PACKAGE, False)


if __name__ == "__main__":
    unittest.main()
