import os
import sys
import types
import unittest

# The cloud libraries are only installed in the function's runtime.
ff = types.ModuleType("functions_framework")
ff.cloud_event = lambda f: f
sys.modules.setdefault("functions_framework", ff)
google = sys.modules.setdefault("google", types.ModuleType("google"))
auth = types.ModuleType("google.auth")
transport = types.ModuleType("google.auth.transport")
requests_mod = types.ModuleType("google.auth.transport.requests")
requests_mod.AuthorizedSession = object
google.auth = auth
for name, mod in [("google.auth", auth), ("google.auth.transport", transport), ("google.auth.transport.requests", requests_mod)]:
    sys.modules.setdefault(name, mod)

os.environ.setdefault("PROJECT_ID", "test")
import main  # noqa: E402


class OverBudget(unittest.TestCase):
    def test_under(self):
        self.assertFalse(main.over_budget({"costAmount": 0.4, "budgetAmount": 1}))

    def test_equal_is_not_over(self):
        self.assertFalse(main.over_budget({"costAmount": 1, "budgetAmount": 1}))

    def test_over(self):
        self.assertTrue(main.over_budget({"costAmount": 1.01, "budgetAmount": 1}))

    def test_missing_fields(self):
        self.assertFalse(main.over_budget({}))


if __name__ == "__main__":
    unittest.main()
