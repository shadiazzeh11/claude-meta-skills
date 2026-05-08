import unittest


class TestPass(unittest.TestCase):
    def test_basic_arithmetic(self):
        self.assertEqual(1 + 1, 2)

    def test_string_concat(self):
        self.assertEqual("hello" + " " + "world", "hello world")
