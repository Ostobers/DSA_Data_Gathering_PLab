"""Unit tests for Phase C trusted survey validation (no SQL Server required)."""

from __future__ import annotations

import unittest

from survey_validation import compile_show, validate_survey_answers


def q(code, qtype, *, required=True, spec=None, **extra):
    specification = {"id": code, "type": qtype, **(spec or {}), **extra}
    return {
        "question_code": code,
        "question_type": qtype,
        "is_required": required,
        "specification_json": specification,
    }


CONTEXT = {
    "EMP": ["Employed full-time", "Employed part-time", "Self-employed / freelance"],
    "NOSEARCH": [
        "I plan to continue my education (PhD or other program)",
        "I am not seeking work after graduation",
    ],
}


class ShowCompileTests(unittest.TestCase):
    def test_equality_and_negated_const(self):
        eq = compile_show("a=>a['A-6']=='Yes'")
        self.assertTrue(eq({"A-6": "Yes"}))
        self.assertFalse(eq({"A-6": "No"}))

        nosearch = compile_show("a=>!NOSEARCH.includes(a.A2)", CONTEXT)
        self.assertTrue(nosearch({"A2": "I am actively searching for a job or internship"}))
        self.assertFalse(
            nosearch({"A2": "I am not seeking work after graduation"})
        )

    def test_emp_includes_and_length(self):
        emp = compile_show("a=>EMP.includes(a.B2)", CONTEXT)
        self.assertTrue(emp({"B2": "Employed full-time"}))
        self.assertFalse(emp({"B2": "Seeking employment"}))

        length = compile_show("a=>a['B-4'].length>0")
        self.assertTrue(length({"B-4": ["DSA 501"]}))
        self.assertFalse(length({"B-4": []}))

    def test_array_includes_and_multi_includes(self):
        arr = compile_show(
            "a=>!['All completed','No previous action items'].includes(a['S3-4'])"
        )
        self.assertTrue(arr({"S3-4": "Some remaining"}))
        self.assertFalse(arr({"S3-4": "All completed"}))

        multi = compile_show("a=>!a['S5-12'].includes('No opportunity')")
        self.assertTrue(multi({"S5-12": ["Internship", "Project"]}))
        self.assertFalse(multi({"S5-12": ["No opportunity"]}))

    def test_rejects_arbitrary_code(self):
        with self.assertRaises(ValueError):
            compile_show("a=>eval('1')")
        with self.assertRaises(ValueError):
            compile_show("a=>process.exit(1)")


class ValidationTests(unittest.TestCase):
    def test_pulse_submit_requires_visible_answers(self):
        questions = [
            q("C1", "single", o=["1", "2", "3", "4", "5"]),
            q("C8", "long", required=False, req=False),
        ]
        ok, err = validate_survey_answers(
            questions, {"C1": "3"}, submit=True, source_context=CONTEXT
        )
        self.assertTrue(ok, err)

        ok, err = validate_survey_answers(questions, {}, submit=True)
        self.assertFalse(ok)
        self.assertIn("C1", err)

    def test_show_hides_required_followup(self):
        questions = [
            q("A9", "single", o=["Yes", "No"]),
            q(
                "A10",
                "email",
                spec={"show": {"javascript_source": "a=>a.A9=='Yes'"}},
            ),
        ]
        ok, err = validate_survey_answers(
            questions, {"A9": "No"}, submit=True, source_context=CONTEXT
        )
        self.assertTrue(ok, err)

        ok, err = validate_survey_answers(
            questions, {"A9": "Yes"}, submit=True, source_context=CONTEXT
        )
        self.assertFalse(ok)
        self.assertIn("A10", err)

        ok, err = validate_survey_answers(
            questions,
            {"A9": "Yes", "A10": "not-an-email"},
            submit=True,
            source_context=CONTEXT,
        )
        self.assertFalse(ok)
        self.assertIn("email", err.lower())

        ok, err = validate_survey_answers(
            questions,
            {"A9": "Yes", "A10": "grad@example.com"},
            submit=True,
            source_context=CONTEXT,
        )
        self.assertTrue(ok, err)

    def test_grid_and_each(self):
        questions = [
            q("B-4", "multi", o=["DSA 501", "DSA 502"]),
            q(
                "B-5",
                "each",
                o=["1", "2", "3", "4"],
                src="B-4",
                spec={
                    "src": "B-4",
                    "o": ["1", "2", "3", "4"],
                    "show": {"javascript_source": "a=>a['B-4'].length>0"},
                },
            ),
            q(
                "S1-2",
                "grid",
                o=["Low", "High"],
                rows=["Python", "SQL"],
                spec={"o": ["Low", "High"], "rows": ["Python", "SQL"]},
            ),
        ]
        ok, err = validate_survey_answers(
            questions,
            {
                "B-4": ["DSA 501"],
                "B-5": {"DSA 501": "3"},
                "S1-2": {"Python": "Low", "SQL": "High"},
            },
            submit=True,
        )
        self.assertTrue(ok, err)

        ok, err = validate_survey_answers(
            questions,
            {"B-4": ["DSA 501", "DSA 502"], "B-5": {"DSA 501": "3"}, "S1-2": {"Python": "Low"}},
            submit=True,
        )
        self.assertFalse(ok)

    def test_repeat_nested_show_and_draft_skips_required(self):
        questions = [
            q(
                "S5-courses",
                "repeat",
                spec={
                    "o": [
                        {"id": "course", "t": "Course", "type": "text"},
                        {
                            "id": "preparation",
                            "t": "Prep",
                            "type": "single",
                            "o": [
                                "Required prerequisite course",
                                "Existing requirements were sufficient",
                            ],
                        },
                        {
                            "id": "preparation_skills",
                            "t": "Skills",
                            "type": "multi",
                            "o": ["Python", "SQL"],
                            "show": {
                                "javascript_source": (
                                    "a=>['Required prerequisite course'].includes(a.preparation)"
                                )
                            },
                        },
                    ]
                },
            )
        ]
        # Draft may be partial.
        ok, err = validate_survey_answers(
            questions, {"S5-courses": [{"course": "DSA 501"}]}, submit=False
        )
        self.assertTrue(ok, err)

        ok, err = validate_survey_answers(
            questions,
            {
                "S5-courses": [
                    {
                        "course": "DSA 501",
                        "preparation": "Required prerequisite course",
                    }
                ]
            },
            submit=True,
        )
        self.assertFalse(ok)
        self.assertIn("preparation_skills", err)

        ok, err = validate_survey_answers(
            questions,
            {
                "S5-courses": [
                    {
                        "course": "DSA 501",
                        "preparation": "Required prerequisite course",
                        "preparation_skills": ["Python"],
                    }
                ]
            },
            submit=True,
        )
        self.assertTrue(ok, err)

    def test_never_executes_javascript_source(self):
        questions = [
            q(
                "X1",
                "single",
                o=["Yes"],
                spec={
                    "o": ["Yes"],
                    "show": {"javascript_source": "a=>__import__('os').system('true') or True"},
                },
            )
        ]
        ok, err = validate_survey_answers(questions, {"X1": "Yes"}, submit=True)
        self.assertFalse(ok)
        self.assertIn("Unrecognized", err)


class CanonicalJsonNotes(unittest.TestCase):
    def test_idempotent_payload_stable_dumps(self):
        import json

        # Mirrors db.canonical_answers_json (avoid importing SQLAlchemy in unit tests).
        def canonical_answers_json(answers):
            return json.dumps(answers, ensure_ascii=False, separators=(",", ":"))

        answers = {"C1": "3", "C2": "4", "C8": "hello"}
        a = canonical_answers_json(answers)
        b = canonical_answers_json(json.loads(a))
        self.assertEqual(a, b)
        # Proc compares binary equality; retries must resend the same object order.
        self.assertEqual(a, '{"C1":"3","C2":"4","C8":"hello"}')


if __name__ == "__main__":
    unittest.main()
