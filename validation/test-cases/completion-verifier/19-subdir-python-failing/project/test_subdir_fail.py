import unittest


class TestSubdirFail(unittest.TestCase):
    def test_intentional_failure_from_project_root(self):
        self.assertEqual(1, 2, "intentional failure from project root")
