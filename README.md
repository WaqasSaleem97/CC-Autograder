# CC Autograder

This generalized workflow grades any trusted assessment directory in approved students' repositories. Assessment category, name, repository, submission path, test script, maximum marks, branch, section, and student selection are entered when the workflow runs.

## Required GitHub settings

- Variable `FIREBASE_PROJECT_ID`
- Secret `FIREBASE_SERVICE_ACCOUNT`
- Secret `STUDENT_REPOS_TOKEN` only when private student repositories must be cloned
- Secret `GMAIL_USER` containing the Gmail address that sends results
- Secret `GMAIL_APP_PASSWORD` containing a dedicated 16-character Google App Password
- Optional variable `EMAIL_FROM_NAME`, for example `CC Autograder`
- Optional variable `EMAIL_REPLY_TO` for student questions

If a repository cannot be collected or a trusted test crashes or times out, the
student is reported as `NOT GRADED`. Infrastructure errors are skipped during
the Firestore update and are never converted into zero marks.

## Emailing results through Gmail

Enable 2-Step Verification on the sender's Google account and create a dedicated
App Password. Save the Gmail address and App Password as the repository secrets
listed above; never commit either value. The normal Google account password must
not be used.

When starting the grading workflow, enable `send_email_results`. The trusted
publishing job reloads current student records from Firestore and sends one
private message per valid student email address. Each message contains the
score, summary, repository, grading time, and a table of every passed, missing,
manual-review, or failed check. Students with no valid email address are
skipped without printing their address. Keep the option disabled when rerunning a workflow
unless the result emails should be sent again.

## Student selection

- `All` with `Both` grades every approved student in both sections.
- `All` with `A` or `B` grades that section.
- `Registration numbers` grades only the comma-separated numbers that also match the selected section.

## Test-script contract

The workflow calls:

```bash
bash tests/YourTest/test.sh /absolute/student/submission/path TOTAL_MARKS
```

The final output line must be JSON:

```json
{"score":8,"feedback":"terraform fmt: 2/2; validate: 3/3; required resources: 3/5"}
```

Create different trusted scripts for Git/GitHub, Linux, AWS configuration, Terraform, Ansible, and Docker assessments. Never place Firebase or AWS credentials in the grading job.

For Lab 01 and Lab 02, GitHub usernames are normalized to lowercase before
Ubuntu identity checks. Screenshot extensions are ignored, including repeated
image extensions such as `.png.png`; the required filename before the extension
must still match. Shared OCR preprocessing checks browser pages, terminals, and
bright fields in the dark Ubuntu installer UI. It tolerates a small number of
OCR character errors in long usernames without accepting unrelated identities.

Lab 01 now makes automatic pass/fail decisions for missing, ambiguous, corrupt,
unreadable, wrong-task, wrong-identity, and copied instructor-reference files.
Only a byte-identical screenshot shared by multiple students keeps provisional
credit and requests manual review, because automation cannot reliably identify
the original owner. Perceptually similar standard installer screens are not
flagged as duplicates.

## Install and verify

```bash
npm install
npm run check
```

Commit `package-lock.json` so GitHub Actions can run `npm ci`.
