import unittest


class TestFail(unittest.TestCase):
    def test_intentional_failure(self):
        self.assertEqual(1, 2, "intentional failure for hook validation")
