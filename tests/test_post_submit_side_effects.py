"""Unit tests for Phase F pure helpers (no SQL Server required)."""

import os
import unittest
from datetime import date
from unittest import mock

import db


class AddCalendarMonthsTests(unittest.TestCase):
    def test_simple_add(self):
        self.assertEqual(db.add_calendar_months(date(2026, 1, 15), 3), date(2026, 4, 15))

    def test_clamps_end_of_month(self):
        self.assertEqual(db.add_calendar_months(date(2026, 1, 31), 1), date(2026, 2, 28))

    def test_year_rollover(self):
        self.assertEqual(db.add_calendar_months(date(2026, 11, 1), 3), date(2027, 2, 1))


class ContactPermissionTests(unittest.TestCase):
    def test_yes_with_email(self):
        parsed = db.parse_contact_permission(
            {"A9": "Yes", "A10": " Grad@Example.COM "}
        )
        self.assertEqual(
            parsed,
            {
                "allow_graduate_contact": True,
                "personal_email": "grad@example.com",
            },
        )

    def test_no_clears_email(self):
        parsed = db.parse_contact_permission(
            {"A9": "No", "A10": "should-be-ignored@example.com"}
        )
        self.assertEqual(
            parsed,
            {"allow_graduate_contact": False, "personal_email": None},
        )

    def test_absent_a9(self):
        self.assertIsNone(db.parse_contact_permission({"C1": "3"}))


class FollowUpExtractionTests(unittest.TestCase):
    def test_extracts_yes_pairs(self):
        answers = {
            "L1-18": "Yes",
            "L1-18a": "Need course planning help",
            "L2-18": "No",
            "S4-8": "Yes",
            "S4-8a": "Resume review",
            "C5": "Yes",
        }
        rows = db.extract_follow_up_requests(answers)
        codes = {r["ask_code"] for r in rows}
        self.assertEqual(codes, {"L1-18", "S4-8", "C5"})
        by_ask = {r["ask_code"]: r for r in rows}
        self.assertEqual(by_ask["L1-18"]["details"], "Need course planning help")
        self.assertEqual(by_ask["C5"]["topic"], "Advising request (pulse)")

    def test_no_yes_means_empty(self):
        self.assertEqual(db.extract_follow_up_requests({"L1-18": "No"}), [])


class GraduateAssignmentHelpersTests(unittest.TestCase):
    def test_event_key(self):
        self.assertEqual(db.graduate_assignment_event_key(6), "after_0:m6")

    def test_bad_month(self):
        with self.assertRaises(ValueError):
            db.graduate_assignment_event_key(9)

    def test_notice_version_label(self):
        label = db.notice_version_label(
            survey_code="near_0", version_number=1, variant="short"
        )
        self.assertEqual(label, "near_0:v1:short")


class GraduateOutcomesMapperTests(unittest.TestCase):
    def test_maps_employment_shape(self):
        mapped = db.map_graduate_outcomes_row(
            {
                "user_id": 9,
                "response_id": 44,
                "submitted_at": date(2026, 9, 1),
                "graduation_term": "Spring 2026",
                "employment_status": "Employed full-time",
                "months_to_job": 1,
                "job_title": "Data analyst",
                "industry": "Healthcare",
                "uses_ds_skills": "Yes, mostly",
                "salary_range": "$70,000 to $79,999",
                "employment_preparation": 4,
            }
        )
        self.assertEqual(mapped["status"], "Employed full-time")
        self.assertEqual(mapped["title"], "Data analyst")
        self.assertEqual(mapped["uses_ds"], "Yes, mostly")
        self.assertIn("R10", mapped["r10_note"])


class AlertsHookFlagTests(unittest.TestCase):
    def tearDown(self):
        db.clear_after_submit_hooks()
        os.environ.pop("DSA_ALERTS_EVAL_ENABLED", None)

    def test_hooks_skipped_when_flag_off(self):
        calls = []
        db.register_after_submit_hook(
            lambda result, payload, actor: calls.append(actor)
        )
        os.environ["DSA_ALERTS_EVAL_ENABLED"] = "0"
        db.run_after_submit_hooks({"response_id": 1}, {"answers": {}}, 7)
        self.assertEqual(calls, [])

    def test_hooks_run_when_flag_on(self):
        calls = []
        db.register_after_submit_hook(
            lambda result, payload, actor: calls.append((actor, result["response_id"]))
        )
        os.environ["DSA_ALERTS_EVAL_ENABLED"] = "1"
        db.run_after_submit_hooks({"response_id": 42}, {"answers": {}}, 7)
        self.assertEqual(calls, [(7, 42)])


class ApplySideEffectsDispatchTests(unittest.TestCase):
    """apply_post_submit_side_effects with SQL helpers mocked."""

    def tearDown(self):
        db.clear_after_submit_hooks()

    @mock.patch("db.ensure_graduate_followup_assignments", return_value=[{"m": 3}])
    @mock.patch("db.cancel_graduate_followup_assignments", return_value=0)
    @mock.patch("db.insert_follow_up_request", return_value=99)
    @mock.patch("db.upsert_contact_preferences")
    @mock.patch("db.fetch_survey_version_meta")
    def test_near_grad_yes_path(
        self,
        mock_meta,
        mock_upsert,
        mock_follow,
        mock_cancel,
        mock_assign,
    ):
        mock_meta.return_value = {
            "survey_version_id": 2,
            "survey_code": "near_0",
            "version_number": 1,
            "variant": "short",
        }
        mock_upsert.return_value = {
            "user_id": 5,
            "allow_graduate_contact": True,
            "personal_email": "a@b.com",
            "notice_version": "near_0:v1:short",
        }
        summary = db.apply_post_submit_side_effects(
            {"response_id": 10, "survey_version_id": 2},
            {
                "answers": {
                    "A9": "Yes",
                    "A10": "a@b.com",
                    "A8": "Yes",
                },
                "survey_version_id": 2,
            },
            5,
        )
        mock_upsert.assert_called_once()
        mock_assign.assert_called_once_with(user_id=5)
        mock_cancel.assert_not_called()
        mock_follow.assert_called()  # A8 Yes
        self.assertEqual(summary["follow_up_ids"], [99])
        self.assertEqual(summary["graduate_assignments"], [{"m": 3}])

    @mock.patch("db.ensure_graduate_followup_assignments")
    @mock.patch("db.cancel_graduate_followup_assignments", return_value=2)
    @mock.patch("db.insert_follow_up_request")
    @mock.patch("db.upsert_contact_preferences")
    @mock.patch("db.fetch_survey_version_meta")
    def test_near_grad_withdrawal_cancels(
        self,
        mock_meta,
        mock_upsert,
        mock_follow,
        mock_cancel,
        mock_assign,
    ):
        mock_meta.return_value = {
            "survey_code": "near_0",
            "version_number": 1,
            "variant": "long",
        }
        mock_upsert.return_value = {
            "allow_graduate_contact": False,
            "personal_email": None,
        }
        summary = db.apply_post_submit_side_effects(
            {"response_id": 11, "survey_version_id": 3},
            {"answers": {"A9": "No"}, "survey_version_id": 3},
            8,
        )
        mock_cancel.assert_called_once_with(user_id=8)
        mock_assign.assert_not_called()
        mock_follow.assert_not_called()
        self.assertEqual(summary["cancelled_assignments"], 2)


if __name__ == "__main__":
    unittest.main()
