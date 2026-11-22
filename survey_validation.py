"""Trusted Flask validation for survey answers (Phase C / R15).

Reimplements show/branching, nested repeats, grids/each completeness, and
email checks from question specifications. Never executes
specification_json.show.javascript_source (reference metadata only).

Recognized show expression shapes match the seeded questionnaire corpus and
EMP/NOSEARCH constants from survey_versions.source_context_json.
"""

from __future__ import annotations

import json
import re
from typing import Any, Callable, Mapping, Optional, Sequence

EMAIL_RE = re.compile(r"^\S+@\S+\.\S+$")

# a.A2  or  a['S3-4']  or  a["S3-4"]
_ANSWER_REF = re.compile(
    r"^a(?:\.([A-Za-z_][A-Za-z0-9_-]*)|\[['\"]([^'\"]+)['\"]\])$"
)
_STR = r"'(?:\\'|[^'])*'|\"(?:\\\"|[^\"])*\""
_ARRAY = rf"\[(?:\s*(?:{_STR})\s*,)*\s*(?:{_STR})\s*\]"


def _parse_string_literal(token: str) -> str:
    if token.startswith("'"):
        return (
            token[1:-1]
            .replace("\\'", "'")
            .replace('\\"', '"')
            .replace("\\n", "\n")
            .replace("\\\\", "\\")
        )
    return json.loads(token)


def _parse_string_array(token: str) -> list[str]:
    # Seeded arrays use single-quoted JS strings; normalize for json.loads.
    normalized = "[" + ",".join(
        json.dumps(_parse_string_literal(m.group(0)))
        for m in re.finditer(_STR, token)
    ) + "]"
    return json.loads(normalized)


def _resolve_answer_ref(ref: str, answers: Mapping[str, Any]) -> Any:
    m = _ANSWER_REF.match(ref.strip())
    if not m:
        raise ValueError(f"Unsupported answer reference: {ref}")
    key = m.group(1) or m.group(2)
    return answers.get(key)


def compile_show(
    javascript_source: str,
    context: Optional[Mapping[str, Any]] = None,
) -> Callable[[Mapping[str, Any]], bool]:
    """Compile a seeded show.javascript_source into a safe predicate.

    Raises ValueError for unrecognized expressions (fail closed).
    """
    src = (javascript_source or "").strip()
    if not src.startswith("a=>"):
        raise ValueError("show expression must start with a=>")
    body = src[3:].strip()
    ctx = dict(context or {})

    negate = False
    if body.startswith("!"):
        negate = True
        body = body[1:].strip()

    def wrap(fn: Callable[[Mapping[str, Any]], bool]) -> Callable[[Mapping[str, Any]], bool]:
        if negate:
            return lambda a: not fn(a)
        return fn

    # CONST.includes(a.X)
    m = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\.includes\((.+)\)$", body)
    if m and m.group(1) not in ("a",):
        const_name, ref = m.group(1), m.group(2)
        if const_name not in ctx:
            raise ValueError(f"Unknown show context constant: {const_name}")
        values = list(ctx[const_name])

        def pred_const(a: Mapping[str, Any], values=values, ref=ref) -> bool:
            return _resolve_answer_ref(ref, a) in values

        return wrap(pred_const)

    # ['x','y'].includes(a.X)
    m = re.fullmatch(rf"({_ARRAY})\.includes\((.+)\)$", body)
    if m:
        values = _parse_string_array(m.group(1))
        ref = m.group(2)

        def pred_arr(a: Mapping[str, Any], values=values, ref=ref) -> bool:
            return _resolve_answer_ref(ref, a) in values

        return wrap(pred_arr)

    # a.X.includes('text')  — multi-select membership
    m = re.fullmatch(rf"(.+)\.includes\(({_STR})\)$", body)
    if m:
        ref, lit = m.group(1), _parse_string_literal(m.group(2))

        def pred_includes(a: Mapping[str, Any], ref=ref, lit=lit) -> bool:
            val = _resolve_answer_ref(ref, a)
            if isinstance(val, list):
                return lit in val
            if isinstance(val, str):
                return lit in val
            return False

        return wrap(pred_includes)

    # a.X.length>0
    m = re.fullmatch(r"(.+)\.length\s*>\s*0$", body)
    if m:
        ref = m.group(1)

        def pred_len(a: Mapping[str, Any], ref=ref) -> bool:
            val = _resolve_answer_ref(ref, a)
            try:
                return len(val) > 0  # type: ignore[arg-type]
            except TypeError:
                return False

        return wrap(pred_len)

    # a.X=='...' / a.X!='...'
    m = re.fullmatch(rf"(.+?)(==|!=)({_STR})$", body)
    if m:
        ref, op, lit = m.group(1), m.group(2), _parse_string_literal(m.group(3))

        def pred_cmp(a: Mapping[str, Any], ref=ref, op=op, lit=lit) -> bool:
            val = _resolve_answer_ref(ref, a)
            return (val == lit) if op == "==" else (val != lit)

        return wrap(pred_cmp)

    raise ValueError(f"Unrecognized show expression: {javascript_source}")


def _spec_dict(question: Mapping[str, Any]) -> dict[str, Any]:
    raw = question.get("specification_json")
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        return json.loads(raw)
    return {}


def _is_required(question: Mapping[str, Any], spec: Mapping[str, Any]) -> bool:
    if "req" in spec:
        return bool(spec["req"])
    if "is_required" in question:
        return bool(question["is_required"])
    return True


def _show_predicate(
    spec: Mapping[str, Any],
    context: Optional[Mapping[str, Any]],
) -> Optional[Callable[[Mapping[str, Any]], bool]]:
    show = spec.get("show")
    if not show:
        return None
    if isinstance(show, dict) and "javascript_source" in show:
        return compile_show(show["javascript_source"], context)
    raise ValueError("show metadata must use javascript_source reference form")


def _answer_present(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return value.strip() != ""
    if isinstance(value, (list, dict)):
        return len(value) > 0
    return True


def _validate_scalar_field(
    *,
    code: str,
    field_type: str,
    value: Any,
    options: Any,
    max_sel: Optional[int],
    exclusive: Optional[Sequence[str]],
    rows: Optional[Sequence[str]],
) -> Optional[str]:
    if field_type in ("single", "dropdown", "text", "long", "email"):
        if not isinstance(value, str):
            return f"{code}: expected a string answer."
        if field_type in ("single", "dropdown") and isinstance(options, list):
            if value and value not in options:
                return f"{code}: selected option is not allowed."
        if field_type == "email" and value and not EMAIL_RE.match(value):
            return f"{code}: invalid email address."
        return None

    if field_type == "number":
        if isinstance(value, bool):
            return f"{code}: expected a number."
        if isinstance(value, (int, float)):
            if value < 0:
                return f"{code}: number must be 0 or greater."
            return None
        if isinstance(value, str):
            if value == "":
                return None
            try:
                num = float(value)
            except ValueError:
                return f"{code}: expected a number."
            if num < 0:
                return f"{code}: number must be 0 or greater."
            return None
        return f"{code}: expected a number."

    if field_type == "multi":
        if not isinstance(value, list):
            return f"{code}: expected an array of selections."
        if len(value) != len(set(value)):
            return f"{code}: duplicate selections are not allowed."
        if isinstance(options, list):
            for item in value:
                if not isinstance(item, str) or item not in options:
                    return f"{code}: selected option is not allowed."
        if max_sel is not None and len(value) > max_sel:
            return f"{code}: select at most {max_sel}."
        if exclusive and len(value) > 1:
            for item in value:
                if item in exclusive:
                    return f"{code}: exclusive option cannot be combined."
        return None

    if field_type == "grid":
        if not isinstance(value, dict):
            return f"{code}: expected an object of row answers."
        if rows:
            for row in rows:
                if row not in value or not _answer_present(value.get(row)):
                    return f"{code}: please answer every row."
                cell = value[row]
                if isinstance(options, list) and cell not in options:
                    return f"{code}: grid option is not allowed."
        return None

    if field_type == "each":
        if not isinstance(value, dict):
            return f"{code}: expected an object of per-item answers."
        return None

    if field_type == "repeat":
        if not isinstance(value, list):
            return f"{code}: expected an array of repeat items."
        return None

    return f"{code}: unsupported question type {field_type}."


def _validate_repeat_item(
    item: Any,
    fields: Sequence[Mapping[str, Any]],
    *,
    code: str,
    submit: bool,
    context: Optional[Mapping[str, Any]],
) -> Optional[str]:
    if not isinstance(item, dict):
        return f"{code}: each repeat item must be an object."

    visible_answers: dict[str, Any] = {}
    for field in fields:
        fid = field.get("id")
        if not isinstance(fid, str):
            continue
        ftype = field.get("type") or "text"
        pred = _show_predicate(field, context)
        visible = True if pred is None else bool(pred(visible_answers))
        if not visible:
            continue
        if fid in item:
            visible_answers[fid] = item[fid]
        required = field.get("req", True) is not False
        value = item.get(fid)
        if submit and required and not _answer_present(value):
            return f"{code}.{fid}: required field is unanswered."
        if fid not in item:
            continue
        err = _validate_scalar_field(
            code=f"{code}.{fid}",
            field_type=str(ftype),
            value=value,
            options=field.get("o"),
            max_sel=field.get("max"),
            exclusive=field.get("ex"),
            rows=field.get("rows"),
        )
        if err:
            return err
        other_key = f"{fid}_other"
        if other_key in item and not isinstance(item[other_key], str):
            return f"{code}.{other_key}: expected a string."
        if (
            submit
            and isinstance(field.get("o"), list)
            and "Other" in field["o"]
            and not field.get("oo")
            and value == "Other"
            and not _answer_present(item.get(other_key))
        ):
            return f"{code}.{fid}: please specify Other."
        if (
            submit
            and isinstance(value, list)
            and "Other" in value
            and not field.get("oo")
            and not _answer_present(item.get(other_key))
        ):
            return f"{code}.{fid}: please specify Other."
    return None


def validate_survey_answers(
    questions: Sequence[Mapping[str, Any]],
    answers: Mapping[str, Any],
    *,
    submit: bool,
    source_context: Optional[Mapping[str, Any]] = None,
) -> tuple[bool, Optional[str]]:
    """Validate answers against DB question rows.

    On submit=True, enforce required applicable questions (including show),
    grids/each completeness, nested repeats, and emails.
    On submit=False (draft), only validate present values' shapes/options.
    """
    if not isinstance(answers, dict):
        return False, "answers must be a JSON object."

    context = dict(source_context or {})
    # Accumulate prior answers for show evaluation (questionnaire order).
    visible_so_far: dict[str, Any] = {}
    by_code = []
    for q in questions:
        code = q.get("question_code") or q.get("id")
        if not code:
            continue
        spec = _spec_dict(q)
        qtype = q.get("question_type") or spec.get("type")
        by_code.append((str(code), str(qtype), q, spec))

    known_codes = {code for code, _, _, _ in by_code}
    for key in answers:
        if not isinstance(key, str):
            return False, "answer keys must be strings."
        base = key
        if key.endswith("_other") or key.endswith("_why"):
            base = key.rsplit("_", 1)[0]
        if base not in known_codes:
            return False, f"Unknown answer key: {key}."

    for code, qtype, question, spec in by_code:
        try:
            pred = _show_predicate(spec, context)
            visible = True if pred is None else bool(pred(visible_so_far))
        except ValueError as exc:
            return False, f"{code}: {exc}"

        if visible and code in answers:
            visible_so_far[code] = answers[code]

        if not visible:
            continue

        required = _is_required(question, spec)
        value = answers.get(code)

        if code not in answers:
            if submit and required and qtype == "each":
                src = spec.get("src")
                src_vals = visible_so_far.get(src) if src else None
                if isinstance(src_vals, list) and len(src_vals) > 0:
                    return False, f"{code}: required question is unanswered."
            elif submit and required and qtype != "each":
                return False, f"{code}: required question is unanswered."
            continue

        if submit and required and qtype != "each" and not _answer_present(value):
            return False, f"{code}: required question is unanswered."

        err = _validate_scalar_field(
            code=code,
            field_type=qtype,
            value=value,
            options=spec.get("o") if qtype != "repeat" else None,
            max_sel=spec.get("max"),
            exclusive=spec.get("ex"),
            rows=spec.get("rows"),
        )
        if err:
            return False, err

        if qtype == "each":
            src = spec.get("src")
            src_vals = visible_so_far.get(src) if src else []
            if not isinstance(src_vals, list):
                src_vals = []
            if not isinstance(value, dict):
                return False, f"{code}: expected an object of per-item answers."
            options = spec.get("o") if isinstance(spec.get("o"), list) else []
            for item in src_vals:
                if submit and (
                    item not in value or not _answer_present(value.get(item))
                ):
                    return False, f"{code}: please answer every item."
                if item in value and options and value[item] not in options:
                    return False, f"{code}: option is not allowed."

        if qtype == "grid" and submit and required:
            rows = spec.get("rows") or []
            if not isinstance(value, dict) or len(value) < len(rows):
                return False, f"{code}: please answer every row."

        if qtype == "repeat":
            fields = spec.get("o") if isinstance(spec.get("o"), list) else []
            if not isinstance(value, list):
                return False, f"{code}: expected an array of repeat items."
            if submit and required and len(value) == 0:
                return False, f"{code}: required question is unanswered."
            for item in value:
                nested_err = _validate_repeat_item(
                    item,
                    fields,
                    code=code,
                    submit=submit,
                    context=context,
                )
                if nested_err:
                    return False, nested_err

        other_key = f"{code}_other"
        if other_key in answers and not isinstance(answers[other_key], str):
            return False, f"{other_key}: expected a string."
        why_key = f"{code}_why"
        if why_key in answers and not isinstance(answers[why_key], str):
            return False, f"{why_key}: expected a string."

        if (
            submit
            and isinstance(spec.get("o"), list)
            and "Other" in spec["o"]
            and not spec.get("oo")
        ):
            if value == "Other" and not _answer_present(answers.get(other_key)):
                return False, f"{code}: please specify Other."
            if isinstance(value, list) and "Other" in value and not _answer_present(
                answers.get(other_key)
            ):
                return False, f"{code}: please specify Other."

    return True, None
