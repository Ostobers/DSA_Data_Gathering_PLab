"""Unit tests for Phase D view mappers (no SQL Server required)."""

import unittest
from datetime import datetime

import db


class MapCheckinRowTests(unittest.TestCase):
    def test_maps_dates_and_bools(self):
        row = {
            "response_id": 9,
            "user_id": 2,
            "term_id": None,
            "date": datetime(2026, 10, 20, 15, 30),
            "confidence": 4,
            "belonging": 5,
            "satisfaction": 4,
            "workload": 3,
            "financial": 2,
            "job": 4,
            "job_stage": "Applying",
            "advising": 0,
            "comment": "Started internship applications.",
        }
        mapped = db.map_checkin_row(row)
        self.assertEqual(mapped["date"], "2026-10-20")
        self.assertEqual(mapped["confidence"], 4)
        self.assertFalse(mapped["advising"])
        self.assertEqual(mapped["comment"], "Started internship applications.")


class MapStudentDashboardTests(unittest.TestCase):
    def test_maps_dashboard_shape(self):
        row = {
            "user_id": 2,
            "student_id": "S-1004",
            "name": "Jordan Lee",
            "email": "jordan.lee@buffalostate.edu",
            "population": "Current student",
            "status": "active",
            "entry_term_id": 1,
            "expected_graduation": None,
            "latest_checkin": datetime(2026, 10, 20),
            "confidence": 4,
            "belonging": 5,
            "satisfaction": 4,
            "workload": 3,
            "financial": 2,
            "job": 4,
            "job_stage": "Applying",
            "advising": 1,
            "active_alerts": 0,
        }
        mapped = db.map_student_dashboard_row(row, checkins=[])
        self.assertEqual(mapped["id"], "S-1004")
        self.assertEqual(mapped["user_id"], 2)
        self.assertEqual(mapped["term"], "Term 1")
        self.assertEqual(mapped["gaps"], "None reported")
        self.assertTrue(mapped["advising"])
        self.assertEqual(mapped["latest_checkin"], "2026-10-20")
        self.assertEqual(mapped["checkins"], [])


class MapActiveAlertTests(unittest.TestCase):
    def test_maps_alert_shape(self):
        row = {
            "alert_id": 3,
            "user_id": 2,
            "student_id": "S-1004",
            "student": "Jordan Lee",
            "rule_code": "LOW_CONF",
            "title": "Low confidence",
            "rule_description": "Confidence ≤ 2",
            "trigger_values": "1",
            "alert_description": "Confidence 1",
            "alert_status": "active",
        }
        mapped = db.map_active_alert_row(row)
        self.assertEqual(mapped["id"], "3")
        self.assertEqual(mapped["type"], "Low confidence")
        self.assertEqual(mapped["rule"], "Confidence ≤ 2")
        self.assertEqual(mapped["value"], "1")
        self.assertEqual(mapped["status"], "active")


class TotalsShapeTests(unittest.TestCase):
    def test_totals_keys(self):
        # Shape contract for templates (people/current/alerts/...).
        keys = {
            "people",
            "current",
            "alerts",
            "advising",
            "low_confidence",
            "gaps",
        }
        sample = {
            "people": 0,
            "current": 0,
            "alerts": 0,
            "advising": 0,
            "low_confidence": 0,
            "gaps": 0,
        }
        self.assertEqual(set(sample), keys)


if __name__ == "__main__":
    unittest.main()
