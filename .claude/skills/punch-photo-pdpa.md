---
name: punch-photo-pdpa
description: Use when touching gate punch photos, face capture, `:punch_photo_retention_months`, `PhotoPruner`, employee photos, or CCTV — and ALWAYS before adding face recognition, face matching, embeddings, descriptors, or any "verify the photo is the right person automatically" feature. Also for an employee who refuses face capture, PDPA/biometric/data-protection questions, or a request to lengthen photo retention.
---

# Punch Photo PDPA Constraints

The QR gate stores a cropped face JPEG per punch ([[qr-gate-punch]]). Whether that
is *ordinary* or *sensitive* personal data under Malaysia's PDPA is decided by
**what the code does with it**, not by what is on disk. Several design decisions
that look like scope or effort calls are actually what holds the legal position.

Malaysia's PDPA 2010, as amended by Act A1719 (most provisions in force 2025-01-01), added
**biometric data** to *sensitive personal data*: "personal data resulting from
technical processing relating to the physical, physiological or behavioural
characteristics of a person, which allows or confirms the unique identification
of that person." Sensitive personal data needs **explicit consent** (s.40) and
none of the s.40 exceptions cover attendance.

## The line

| What the code does | Classification | Basis needed |
|---|---|---|
| Stores a JPEG, a human looks at it | Ordinary personal data | s.6 consent (arguably s.6(2)(a), performance of contract) |
| Computes an embedding / runs a matcher | **Sensitive** personal data | s.40 explicit consent — no exception available |

The wording is lifted almost verbatim from GDPR Art 4(14), where Recital 51 says
outright that photographs are not automatically biometric data — only when put
through "a specific technical means allowing the unique identification." A
supervisor squinting at a thumbnail is not a specific technical means. The PDPD
has published no guidance on this point, so the GDPR reading is the persuasive
one, not a settled one.

**Malaysia has no "legitimate interests" lawful basis.** The s.6(2) exceptions
are narrow and there is no catch-all for "reasonable business purpose." Do not
reason from GDPR habits here.

## The prohibition

**Never compute a face embedding or descriptor from a punch photo.**

Doing it once retroactively reclassifies *every* photo in the retention window,
including the ones collected under a notice that promised no such thing. There is
no way to un-ring that bell with a rollback.

This is not negotiable by:

- doing it offline, on a laptop, or in a one-off script
- not persisting the vector
- calling an external API instead of computing locally
- doing it "just to check accuracy" on a sample
- framing it as detection (fine) when it resolves identity (not fine)

`face detection` — is there a face, where is it, is the badge covering it — is
**allowed** and already runs on the phone. It answers "is a face present," never
"whose face." That distinction is the whole thing.

`employee_photos`, with its `photo_descriptor` `{:array, :float}` column, was
dropped in [`20260829000000_drop_employee_photos.exs`](../../priv/repo/migrations/20260829000000_drop_employee_photos.exs).
Nothing in `lib/` or `test/` references it. Do not recreate the table; a
reference photo per employee is legally fine on its own but re-creates the
natural home for a descriptor column.

## Rationalizations

| Excuse | Reality |
|---|---|
| "It's just detection, not recognition" | If the output narrows *who* it is, it's recognition. Detection returns a box, not an identity. |
| "We won't store the vector" | The definition catches the *processing*, not the storage. |
| "A photo is a photo either way" | The file is identical; the classification isn't. Purpose sets the class. |
| "Only for a quick accuracy test" | A sample is still processing, and it's processing nobody consented to. |
| "GDPR allows it under legitimate interests" | Malaysia has no such basis. |
| "The employee already consented to photos" | They consented to a photograph, explicitly not to a face template. |
| "We'd get consent first" | s.40 explicit consent from employees is coerced-consent territory; the alternative path is what makes it valid, and matching has no alternative path. |

## Red flags — stop

- Reaching for Nx, Bumblebee, ONNX, `face_recognition`, or an embeddings API in this repo
- A migration adding a float-array or vector column near `employees` or `time_attendences`
- "Auto-flag punches where the photo doesn't match"
- Lengthening `:punch_photo_retention_months` for convenience
- Piping CCTV into the app

## Retention

**6 months**, `:punch_photo_retention_months` in `config/config.exs`, enforced by
`PunchGate.PhotoPruner`. Cut from 24 on 2026-09-20 as a proportionality call: the
photo is corroborating evidence for a wage dispute, not the wage record, so it
does not need to match payroll register retention. Shorter is easier to defend.
Punch *rows* are kept forever; only JPEGs go.

## An employee who refuses

They can. Consent must be freely given, and an employee consenting to their
employer is weak on power-imbalance grounds. **The existence of a no-detriment
alternative is what makes everyone else's consent valid** — it is not merely an
accommodation for the refuser.

The alternative already exists: `input_medium: "UserEntry"` manual punches
(`punch_time_component.ex`). A supervisor keys them; the Punch Card → PaySlip
flow is unchanged. Zero code.

- Do **not** offer fingerprint as the fallback. Fingerprint templates
  ([[finger-print-import]]) are unambiguously biometric — the stronger case, not
  the weaker one.
- Do **not** build a per-employee `photo_exempt` flag that punches on badge
  alone. It needs server + APK changes and removes the anti-buddy-punching
  control that is the entire justification for capturing the face.
- Never have a supervisor present their own face with the refuser's badge. That
  puts a false face in a record whose only purpose is proving who.

## CCTV

Not in this repo, and keep it that way. Plain footage is ordinary personal data
(same Recital 51 logic), but it is collected for **premises security**, and using
it to establish attendance is a new purpose requiring its own notice and consent.
Using it on someone who declined the gate photo is worse than not accommodating
them at all.

The defensible distinction is **linkage**, not the image: a punch photo is
indexed to an employee ID and timestamp; CCTV is a time-indexed recording of a
place. Wiring them together collapses it.

## What the code already earns

Worth citing verbatim if anyone asks — four of the seven PDPA principles are
enforced in code rather than policy:

| Code fact | Principle |
|---|---|
| No embedding, no matching | Keeps it out of s.40 entirely |
| JPEG cropped to the face, badge cropped **out** | Data minimisation |
| 6-month auto-prune via `PhotoPruner` | Retention |
| Photo route role-gated, 403 not a redirect | Security (and doesn't leak existence) |
| Accepted faces not copied into ingest logs | No shadow copy on a different clock |

Outstanding and **not** solved by code: a written notice in **Bahasa Malaysia and
English** (s.7) stating purpose, that it is a photograph and not a
face-recognition template, retention, who can view it, and access/correction
rights; plus consent recorded and maintained (reg. 3, PDP Regulations 2013).

Not legal advice — this records the design constraints the code relies on, as
understood on 2026-09-20. Confirm with Malaysian counsel before relying on it
externally.
