# CC and DevOps Autograder

This generalized workflow grades trusted CC and DevOps assessments in approved students' repositories. Enter `CC` or `DevOps` as the course ID so the workflow selects the matching course-specific test folder.

The test layout is:

- `tests/CC/` for CC labs and assignments.
- `tests/DevOps/` for DevOps labs and assignments.
- `tests/shared/` for reusable autograder regression tests.

Lab 1, Lab 2, and Lab 3 currently have equivalent graders in both course folders because these labs are common to CC and DevOps.

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
bash tests/CC/YourTest/test.sh /absolute/student/submission/path TOTAL_MARKS
```

The final output line must be JSON:

```json
{"score":8,"feedback":"terraform fmt: 2/2; validate: 3/3; required resources: 3/5"}
```

Create different trusted scripts for Git/GitHub, Linux, AWS configuration, Terraform, Ansible, and Docker assessments. Never place Firebase or AWS credentials in the grading job.

For every screenshot-based assessment, the grading workflow normalizes
screenshot filenames inside its disposable repository clones before running the
trusted test. Filename capitalization and image-extension capitalization are
ignored, and repeated image extensions such as `.png.png` are accepted. The
required filename before the extension must still match. Students' GitHub
repositories are never modified by this normalization.

The screenshot directory name is also case-insensitive. Names such as
`screenshots`, `Screenshots`, `SCREENSHOTS`, and `ScreenShots` are all treated
as the required `screenshots` directory.

For Lab 01 and Lab 02, GitHub usernames are also normalized to lowercase before
Ubuntu identity checks. Shared OCR preprocessing checks browser pages,
terminals, and bright fields in the dark Ubuntu installer UI. It tolerates a
small number of OCR character errors in long usernames without accepting
unrelated identities.

Lab 01 now makes automatic pass/fail decisions for missing, ambiguous, corrupt,
unreadable, wrong-task, wrong-identity, and copied instructor-reference files.
Only a byte-identical screenshot shared by multiple students keeps provisional
credit and requests manual review, because automation cannot reliably identify
the original owner. Perceptually similar standard installer screens are not
flagged as duplicates.

## Assignment 01 grading

The Assignment 01 grader is aligned with the current question in
`CC_F26/Assignments/Assignment01/README.md`.

- The 12 required screenshots account for 90% of the assessment marks.
- `Assignment01.md`, `Assignment01_Solution.docx`, and
  `Assignment01_Solution.pdf` account for the remaining 10%.
- A readable screenshot receives proportional credit for each task indicator
  that OCR can verify; one unclear word no longer makes the complete screenshot
  worth zero.
- For terminal and account-specific browser screenshots, task evidence is 85%
  of that screenshot check and the ownership/identity signal is 15%. Username
  matching is case-insensitive and tolerates small OCR errors in long names.
- A missing identity signal therefore causes only the identity deduction when
  the task itself is visible. Missing, corrupt, unreadable, exact cross-student
  duplicate, or credential-exposing screenshots still receive zero.
- `screenshots` folder capitalization, screenshot filename capitalization,
  image format, and repeated image extensions such as `.png.png` are ignored.
- If the screenshot folder is absent, the three valid assignment files can
  still receive their 10% component instead of the grader exiting early.
- Task 1 verifies the Ubuntu-hosted Gitea and PostgreSQL containers, a successful
  HTTP 200 response, the `Assignment01` Gitea repository, and a real
  `git push -u gitea main`.
- Task 2 verifies safe Gitea and GitHub remotes, a successful GitHub push, and
  the public GitHub `Assignment01` repository.
- Task 3 verifies Git LFS installation and tracking, three `.bin` entries with
  sizes above 100 MiB, and a successful three-object LFS upload.
- Task 4 verifies the public `<username>.github.io` repository with both
  `index.html` and `styles.css`, successful Pages deployment, and the live
  portfolio.
- Visible tokens, passwords, private keys, or credentials embedded in remote
  URLs cause the affected screenshot check to fail.

## Lab 04 grading

The Lab 04 grader is aligned with the current question in
`CC_F26/Labs/Lab04/README.md`.

- The score uses 41 equal required checks: 38 core-task screenshots,
  `workspace/python_project`, `workspace/java_app_copy`, and
  `Lab4_Solution.pdf`.
- `vm_login.png`, `sudo_whoami.png`, and `deluser.png` are optional and do not
  reduce or increase the automated score.
- Bonus Task 7 and all exam-evaluation questions are excluded completely from
  automated grading.
- Main-user terminal evidence must show the registered
  `<github-username>@ubuntu` prompt. After `su - lab4user`, the active prompt
  may instead be `lab4user@ubuntu`. Username matching is case-insensitive and
  tolerates a small number of OCR errors.
- The VMware settings check validates RAM, CPU, disk, and networking without
  requiring a literal product-brand label. SSH evidence accepts a host name or
  an IP address.
- Written answers must identify all required binary directories and contain a
  substantive explanation rather than only listing their names.
- The copied project must preserve `README.md`, `main.py`, and `.env` in
  both required workspace directories. The solution report must be the exact,
  valid `Lab4_Solution.pdf`; an obsolete Word or Markdown report is not
  required.

## Lab 05 grading

The Lab 05 grader is aligned with the current question in
`CC_F26/Labs/Lab05/README.md`.

- The score uses 71 equal required checks: 69 screenshots from Tasks 1 through
  12, `workspace/k8s-sample.yaml`, and `Lab5_Solution.pdf`.
- The Docker Desktop exam evaluation is excluded completely from automated
  grading.
- `task9_vim_install.png` is conditional evidence and is reported without
  increasing or reducing the score.
- Task 8 accepts either the GUI-launch screenshot or the documented CLI-version
  screenshot for Audacity and OBS Studio.
- The shared normalizer ignores screenshot-folder capitalization, screenshot
  filename capitalization, image-extension differences, and repeated image
  extensions such as `.png.png`.
- Terminal identity matching is case-insensitive and tolerates small OCR errors.
- The final Kubernetes manifest must contain the required Pod, annotation,
  container, port, and restart-policy fields; temporary substitutions must have
  been removed.
- The solution report must be the exact, valid `Lab5_Solution.pdf`.

## Install and verify

```bash
npm install
npm run check
```

Commit `package-lock.json` so GitHub Actions can run `npm ci`.
