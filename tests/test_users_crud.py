"""Unit tests for Phase E users CRUD helpers (no SQL Server required)."""

import unittest

import db


class HashPasswordTests(unittest.TestCase):
    def tearDown(self):
        db._PASSWORD_HASHER = None

    def test_temp_placeholder_prefix(self):
        hashed = db.hash_password("demo")
        self.assertTrue(hashed.startswith("TEMP_SHA256:"))
        self.assertLessEqual(len(hashed), 512)
        self.assertEqual(hashed, db.hash_password("demo"))

    def test_pluggable_hasher(self):
        db.register_password_hasher(lambda p: f"custom:{p}")
        self.assertEqual(db.hash_password("secret"), "custom:secret")

    def test_empty_password_rejected(self):
        with self.assertRaises(ValueError):
            db.hash_password("")


class NormalizeTests(unittest.TestCase):
    def test_email_lower_trim(self):
        self.assertEqual(db.normalize_email("  Jordan.Lee@Example.EDU "), "jordan.lee@example.edu")

    def test_username_trim(self):
        self.assertEqual(db.normalize_username("  admin  "), "admin")


class PopulationCheckTests(unittest.TestCase):
    def test_staff_population_null(self):
        self.assertIsNone(
            db.check_safe_population(role="faculty", population="Faculty adviser")
        )
        self.assertIsNone(db.check_safe_population(role="admin", population="x"))

    def test_student_requires_allowed_population(self):
        self.assertEqual(
            db.check_safe_population(role="student", population="Current student"),
            "Current student",
        )
        with self.assertRaises(ValueError):
            db.check_safe_population(role="student", population="Faculty adviser")
        with self.assertRaises(ValueError):
            db.check_safe_population(role="student", population=None)


class MapAccountRowTests(unittest.TestCase):
    def test_maps_v_accounts_shape(self):
        mapped = db.map_account_row(
            {
                "id": 1,
                "username": "admin",
                "name": "Program Administrator",
                "email": "dsa-admin@buffalostate.edu",
                "role": "admin",
                "status": "active",
                "population": "Program administrator",
                "student_id": None,
                "preferred_contact": "email",
            }
        )
        self.assertEqual(mapped["id"], 1)
        self.assertEqual(mapped["role"], "admin")
        self.assertEqual(mapped["population"], "Program administrator")
        self.assertIsNone(mapped["student_id"])


if __name__ == "__main__":
    unittest.main()
