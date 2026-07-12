# CC Autograder

This generalized workflow grades any trusted assessment directory in approved students' repositories. Assessment category, name, repository, submission path, test script, maximum marks, branch, section, and student selection are entered when the workflow runs.

## Required GitHub settings

- Variable `FIREBASE_PROJECT_ID`
- Secret `FIREBASE_SERVICE_ACCOUNT`
- Secret `STUDENT_REPOS_TOKEN` only when private student repositories must be cloned

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

## Install and verify

```bash
npm install
npm run check
```

Commit `package-lock.json` so GitHub Actions can run `npm ci`.

