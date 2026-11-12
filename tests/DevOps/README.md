# DevOps Lab 05 and Lab 06 evidence graders

These are **DevOps** assessments, not the unrelated Linux CC Lab 5/Lab 6 tests.
The existing workflow already routes `DevOps` + `Labs/Lab05` to
`tests/DevOps/Lab5/test.sh`, and `DevOps` + `Labs/Lab06` to
`tests/DevOps/Lab6/test.sh`. No workflow, student-repository or portal migration
is required.

## Source and coverage

| Grader | Authoritative lab | Mandatory screenshots | Required report | Equal-weight checks |
| --- | --- | ---: | --- | ---: |
| `Lab5/test.sh` | [DevOps_F26 Lab05](https://github.com/WaqasSaleem97/DevOps_F26/blob/main/Labs/Lab05/README.md) | 37 | `Lab5_Solution.pdf` | 38 |
| `Lab6/test.sh` | [DevOps_F26 Lab06](https://github.com/WaqasSaleem97/DevOps_F26/blob/main/Labs/Lab06/README.md) | 28 | `Lab6_Solution.pdf` | 29 |

Each rubric pins the exact source commit used to author it. Every screenshot
has equal weight. The mandatory, parseable, non-encrypted solution PDF is one
additional equal-weight deliverable, consistent with the existing lab graders.
PDF answers, captions and completeness require instructor review; the automatic
report check validates the exact filename and PDF structure only.

- Lab 05: IntelliJ setup and four project clones; Maven installation,
  Elasticsearch 7.0.0, package/test/JAR/run/stop/close; Gradle dependency,
  build/JAR/run/stop/close; Node.js/npm installation, app port 4000, Jest and
  tarball; webpack API dependencies/build/bundle; Docker image `lab5:1.0`.
- Lab 06: Nexus on host ports 8006/8007; authenticated HTTP 200; Gradle and
  Maven configuration, build and publication; timestamped snapshot JAR/POM and
  metadata; repository calls as `nexus` and `admin`; component list and details;
  default/mystore blob stores; Docker hosted connector 8007; snapshot cleanup
  policy, scheduled/manual tasks, empty repository, compaction and storage views.
- Lab 05 exam-practice answers and screenshots not listed by the lab are not
  graded. No extra JDK/credentials/setup/role/user screenshots are invented.
- Lab 06 can reuse the existing Maven project. Inspecting the new blob directory
  does not require a second `docker exec`. Instructor IPs, dates, task IDs and
  exact blob sizes are not required. Storage changes and UI selections must
  still be verified during image review.

## Run

Use the existing **Grade approved students** workflow with repository `DevOps`
and submission path `Labs/Lab05` or `Labs/Lab06`. Supply the intended course ID,
assessment name, total marks and student selection. Keep **Manual review**
enabled and leave portal publication/email disabled for the first audited run.

For a read-only local check:

```bash
bash tests/DevOps/Lab5/test.sh /path/to/DevOps/Labs/Lab05 10 Student-Name
bash tests/DevOps/Lab6/test.sh /path/to/DevOps/Labs/Lab06 10 Student-Name
```

The optional username falls back to `STUDENT_GITHUB_USERNAME` and then the
GitHub origin owner. Dependencies are Python 3.10+, Pillow, Git, Tesseract and
Poppler's `pdfinfo`, all installed by the existing workflow.

The final stdout line is JSON containing the score, per-file feedback,
`review_items`, `review_count` and `review_base_points`. The existing image-audit,
review-finalization and email tools can consume it without modification.
Missing student evidence earns zero for that check. A missing grading tool or
trusted-helper failure exits nonzero so the workflow reports **NOT GRADED**
instead of replacing existing marks with zero.

## Evidence and safety policy

- Accept `Screenshots`/`screenshots`, filename capitalization, recognized image
  formats and accidental repeated extensions such as `.PNG.png`.
- Use the shared adaptive OCR and case-insensitive GitHub-username/Ubuntu-prompt
  matcher. A split-screen prompt is valid for browser/editor evidence. OCR is a
  screening aid, not proof that an unsaved form was saved or a UI checkbox was
  selected. Review failures and visual-only requirements before publishing.
- Missing, ambiguous, corrupt, unreadable, wrong-task and wrong-identity
  screenshots receive zero for the affected check.
- Lab 05 accepts both Docker image-list layouts: separate repository/tag
  columns or a combined `lab5:1.0` image reference. The final list must show
  its image ID. The Dockerfile listing need not show an unrelated `app` folder,
  and IntelliJ Welcome evidence need not show the browser address bar; port
  3001 is checked separately in the launch evidence.
- Lab 05 allows OCR spacing around punctuation in the expected Java JAR paths
  and accepts equivalent paths beginning with `./`. It still requires the
  correct artifact/version and startup output. If the initial OCR misses required
  Docker build or final image-list evidence, retry with an enlarged terminal
  pass without relaxing the tag, image ID, or student identity checks.
- Match instructor-reference copies against trusted, pinned Git blob hashes,
  not a student-controlled blacklist. Lab 06's 37 supplied reference PNGs cannot
  be used byte-for-byte as student evidence.
- Exact cross-student copies of the same task receive zero. Conservative visual
  near-duplicates receive provisional credit and manual review; a similar UI
  layout alone must not automatically fail legitimate work. Duplicate comparison
  operates within the workflow's selected sibling `DevOps` repositories.
- Accept Maven `No tests to run` with `BUILD SUCCESS`, both Docker legacy and
  BuildKit success output, and literal or timestamped Nexus snapshot filenames.
- Visible credentials do not reduce marks or trigger manual review on their
  own. The screenshot must still show the correct task evidence and identity.
  Feedback never repeats the secret. OCR audit text containing a detected secret
  is replaced with a redaction notice before it is saved. Original screenshots
  are unchanged and may contain sensitive data; use disposable lab credentials
  and inspect those screenshots privately.
- The grader never builds, starts or executes student code, modifies a student
  repository, contacts a student server or runs Nexus cleanup/compaction.

## Regression checks

```bash
python3 tests/DevOps/criteria_test.py
python3 tests/DevOps/evidence_grader_test.py
npm run check
```

The suites check all 65 exact published screenshot names and valid OCR examples,
negative task/account/port/version/schedule cases, identity, credential handling,
equal-weight scoring, the shell entry points, file normalization, PDF validation,
reference/cross-student copies, isolation and a real Tesseract smoke test. Synthetic
OCR text and images in regression tests are test fixtures, not student evidence.
